import Foundation
import Network

/// HTTP(S) gateway in front of the local engines (oMLX and Splash). Runs in one of two modes:
///
/// - `.local` (127.0.0.1, no key): for Claude Desktop's third-party "gateway" mode. Claude asks for
///   its own model ids (claude-fable-5, …); the gateway lists those ids under the name of the oMLX
///   model assigned to each slot and swaps the model on every request. Modelled on Ollama 0.40's
///   internal/proxy/claude_desktop.go.
/// - `.shared` (all interfaces, a client key required, private-network callers only): lets other
///   computers' tools use the shared models through OpenAI-style (/v1/chat/completions,
///   /v1/completions, /v1/embeddings, /v1/responses) or Anthropic-style (/v1/messages) calls,
///   with per-client limits, usage tracking, optional HTTPS and Bonjour discovery.
///
/// Either way the engines' own keys are added here and never leave this Mac. One request per connection.
final class Gateway {
    enum Kind { case local, shared }

    /// One finished request: numbers only, never prompt or reply text. Kept for the Requests tab.
    struct Activity: Identifiable, Codable, Equatable {
        var id = UUID()
        let date: Date
        let client: String
        let address: String
        let model: String
        let path: String
        let status: Int
        let inputTokens: Int
        let outputTokens: Int
        let seconds: Double
        var engine: String = ""
        var stream = false
        /// Prompt tokens the engine reused from its cache (not read again).
        var cachedTokens = 0
        /// Seconds until the first word (thinking or answer) arrived; nil when unknown.
        var firstWord: Double?

        init(date: Date, client: String, address: String, model: String, path: String, status: Int,
             inputTokens: Int, outputTokens: Int, seconds: Double, engine: String = "", stream: Bool = false,
             cachedTokens: Int = 0, firstWord: Double? = nil) {
            self.date = date; self.client = client; self.address = address; self.model = model; self.path = path
            self.status = status; self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.seconds = seconds
            self.engine = engine; self.stream = stream; self.cachedTokens = cachedTokens; self.firstWord = firstWord
        }

        // Lenient: log lines from older versions lack the newer fields and must still load.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
            date = try c.decode(Date.self, forKey: .date)
            client = (try? c.decode(String.self, forKey: .client)) ?? ""
            address = (try? c.decode(String.self, forKey: .address)) ?? ""
            model = (try? c.decode(String.self, forKey: .model)) ?? ""
            path = (try? c.decode(String.self, forKey: .path)) ?? ""
            status = (try? c.decode(Int.self, forKey: .status)) ?? 0
            inputTokens = (try? c.decode(Int.self, forKey: .inputTokens)) ?? 0
            outputTokens = (try? c.decode(Int.self, forKey: .outputTokens)) ?? 0
            seconds = (try? c.decode(Double.self, forKey: .seconds)) ?? 0
            engine = (try? c.decode(String.self, forKey: .engine)) ?? ""
            stream = (try? c.decode(Bool.self, forKey: .stream)) ?? false
            cachedTokens = (try? c.decode(Int.self, forKey: .cachedTokens)) ?? 0
            firstWord = try? c.decode(Double.self, forKey: .firstWord)
        }

        /// Prompt tokens read per second (the uncached part, over the wait for the first word). Short
        /// prompts are left out: their wait is mostly fixed overhead, not reading.
        var readSpeed: Double? {
            guard let f = firstWord, f > 0.05, inputTokens - cachedTokens >= 500 else { return nil }
            return Double(inputTokens - cachedTokens) / f
        }

        /// Tokens written per second after the first word.
        var writeSpeed: Double? {
            guard stream, let f = firstWord, seconds - f > 0.05, outputTokens > 1 else { return nil }
            return Double(outputTokens) / (seconds - f)
        }
    }

    let kind: Kind
    private var listener: NWListener?
    private let queue: DispatchQueue
    private(set) var port: Int = 0
    private(set) var usingTLS = false
    var config: () -> AppConfig = { AppConfig.load() }
    var onActivity: ((Activity) -> Void)?
    /// Starts a stopped engine when a request asks for one of its models (false = couldn't).
    var ensureEngine: ((EngineKind) async -> Bool)?
    /// The `lsw` command's control calls (this Mac only): status, ensure, use, start, stop.
    var control: ((String, [String: Any]) async -> (Int, [String: Any]))?
    private let limiter = Limiter()

    init(kind: Kind) {
        self.kind = kind
        queue = DispatchQueue(label: "claudelocal.gateway.\(kind)", attributes: .concurrent)
    }

    var isRunning: Bool { listener?.state == .ready }

    /// - Parameters:
    ///   - tlsIdentity: when set, the listener speaks HTTPS with this certificate.
    ///   - bonjourName: when set, the listener is advertised as `_claudelocal._tcp`.
    func start(port: Int, tlsIdentity: sec_identity_t? = nil, bonjourName: String? = nil) throws {
        stop()
        let params: NWParameters
        if let tlsIdentity {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_local_identity(tls.securityProtocolOptions, tlsIdentity)
            sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
            params = NWParameters(tls: tls)
        } else {
            params = NWParameters.tcp
        }
        params.allowLocalEndpointReuse = true
        let nwPort = NWEndpoint.Port(integerLiteral: UInt16(port))
        if kind == .local {
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)
        }
        let l = try (kind == .local ? NWListener(using: params) : NWListener(using: params, on: nwPort))
        if let bonjourName, kind == .shared {
            let txt = NWTXTRecord(["path": "/v1", "scheme": tlsIdentity == nil ? "http" : "https", "app": "LLM Switcher"])
            l.service = NWListener.Service(name: bonjourName, type: "_claudelocal._tcp", txtRecord: txt)
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        let label = kind == .local ? "127.0.0.1" : (tlsIdentity == nil ? "network" : "network (https)")
        l.stateUpdateHandler = { state in
            if case .failed(let err) = state { Log.write("\(label) gateway failed: \(err)") }
            if case .ready = state { Log.write("\(label) gateway listening on port \(port)") }
        }
        l.start(queue: queue)
        listener = l
        self.port = port
        usingTLS = tlsIdentity != nil
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: request reading

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        receiveHead(conn, buffer: Data())
    }

    private func receiveHead(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let end = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[..<end.lowerBound], as: UTF8.self)
                let rest = buf[end.upperBound...]
                guard let req = HTTPRequest(head: head) else { return self.respond(conn, 400, error: "bad request") }
                self.receiveBody(conn, req: req, body: Data(rest))
            } else if err != nil || done || buf.count > 1 << 20 {
                conn.cancel()
            } else {
                self.receiveHead(conn, buffer: buf)
            }
        }
    }

    /// Largest request body accepted (images and long chats fit; a runaway sender doesn't).
    static let maxBody = 512 << 20

    private func receiveBody(_ conn: NWConnection, req: HTTPRequest, body: Data) {
        // Checked before anything else (including the key): a bad length must not crash or fill memory.
        guard req.contentLength >= 0, req.contentLength <= Self.maxBody else {
            return respond(conn, req.contentLength < 0 ? 400 : 413, error: "bad or too large Content-Length")
        }
        if body.count >= req.contentLength {
            return handle(conn, req: req, body: body.prefix(req.contentLength))
        }
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 22) { [weak self] data, _, done, err in
            guard let self else { return }
            var b = body
            if let data { b.append(data) }
            if (err != nil || done) && b.count < req.contentLength { return conn.cancel() }
            self.receiveBody(conn, req: req, body: b)
        }
    }

    // MARK: routing

    private func handle(_ conn: NWConnection, req: HTTPRequest, body: Data) {
        // No browser callers (same rule as Ollama's gateway): a web page could otherwise reach us.
        if req.headers["origin"] != nil { return respond(conn, 403, error: "forbidden", type: "permission_error") }
        let cfg = config()
        let address = Self.clientAddress(conn)
        var client: ShareClient? = nil
        if kind == .shared {
            guard Self.isPrivate(address) else {
                return respond(conn, 403, error: "only devices on the local network may connect", type: "permission_error")
            }
            if req.path != "/health" {
                guard let c = cfg.client(forKey: Self.presentedKey(req)) else {
                    return respond(conn, 401, error: "missing or wrong key", type: "authentication_error")
                }
                guard c.enabled else {
                    return respond(conn, 403, error: "this key is paused on the host Mac", type: "permission_error")
                }
                client = c
            }
        }
        switch (req.method, req.path) {
        case ("GET", "/health"):
            respondJSON(conn, 200, ["ok": true])
        case ("GET", "/v1/models"):
            Task { kind == .local ? await self.serveSlotModels(conn, cfg: cfg) : await self.serveSharedModels(conn, cfg: cfg) }
        case ("GET", "/local/models") where kind == .local:
            Task {
                let catalog = await Engines.catalog(cfg)
                let running = await OMLX.isRunning(upstream: cfg.upstream)
                self.respondJSON(conn, 200, ["models": catalog.keys.sorted(), "omlx_running": running,
                                             "engines": catalog.mapValues(\.engine.rawValue),
                                             "slots": cfg.slots, "slot_ids": Slots.all.map(\.id)])
            }
        case ("GET", "/local/status") where kind == .local:
            Task { await self.runControl(conn, "status", [:]) }
        case ("POST", let p) where kind == .local && ["/local/ensure", "/local/use", "/local/start", "/local/stop", "/local/recommend", "/local/bench"].contains(p):
            let args = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            Task { await self.runControl(conn, String(p.dropFirst("/local/".count)), args) }
        case ("POST", "/v1/messages"), ("POST", "/v1/messages/count_tokens"),
             ("POST", "/v1/chat/completions"), ("POST", "/v1/completions"),
             ("POST", "/v1/embeddings"), ("POST", "/v1/responses"):
            if let client, let refusal = limiter.acquire(client) {
                return respond(conn, 429, error: refusal, type: "rate_limit_error")
            }
            Task {
                await self.route(conn, req: req, body: body, cfg: cfg, client: client, address: address)
            }
        default:
            respond(conn, 404, error: "not found", type: "not_found_error")
        }
    }

    /// Local mode: Claude's slot ids, named after their assigned oMLX models.
    private func serveSlotModels(_ conn: NWConnection, cfg: AppConfig) async {
        let available = Set(await Engines.catalog(cfg).keys)
        var data: [[String: Any]] = []
        for slot in Slots.all {
            // A slot whose engine is stopped is still listed: its first request starts the engine.
            guard let target = cfg.slots[slot.id] else { continue }
            if !available.contains(target), await Self.engineUp(Engines.kind(of: target), cfg) { continue }
            data.append(["id": slot.id, "type": "model", "display_name": target,
                         "created_at": slot.createdAt, "max_tokens": 64000,
                         "anthropic_family_tier": slot.family, "is_family_default": slot.isFamilyDefault])
        }
        respondJSON(conn, 200, ["data": data, "first_id": data.first?["id"] ?? NSNull(),
                                "last_id": data.last?["id"] ?? NSNull(), "has_more": false])
    }

    /// Shared mode: real model names, in a shape both OpenAI- and Anthropic-style clients accept.
    private func serveSharedModels(_ conn: NWConnection, cfg: AppConfig) async {
        let models = Self.sharedModels(cfg, available: await Engines.catalog(cfg).keys.sorted())
        let data: [[String: Any]] = models.map {
            ["id": $0, "object": "model", "type": "model", "owned_by": "claude-local", "display_name": $0, "created": 0]
        }
        respondJSON(conn, 200, ["object": "list", "data": data, "has_more": false])
    }

    static func sharedModels(_ cfg: AppConfig, available: [String]) -> [String] {
        guard let chosen = cfg.sharedModels else { return available }
        return available.filter { chosen.contains($0) }
    }

    private func route(_ conn: NWConnection, req: HTTPRequest, body: Data, cfg: AppConfig,
                       client: ShareClient?, address: String) async {
        let release = { [limiter] in if let client { limiter.release(client) } }
        guard let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            release(); return respond(conn, 400, error: "request body is not JSON")
        }
        let requested = payload["model"] as? String ?? ""
        var catalog = await Engines.catalog(cfg)
        var available = catalog.keys.sorted()
        var allowed = kind == .local ? Set(available) : Set(Self.sharedModels(cfg, available: available))

        // A slot id maps to its model; a real model name passes through.
        var target = cfg.slots[requested] ?? requested
        if Slots.all.contains(where: { $0.id == requested }) && cfg.slots[requested] == nil {
            release()
            return respond(conn, 400, error: "\(requested) is not assigned to a model in LLM Switcher", type: "not_found_error")
        }
        // The model's engine is stopped: start it (it loads the model on this request) and look again.
        let mayUse = kind == .local || cfg.sharedModels == nil || cfg.sharedModels!.contains(target)
        if !target.isEmpty, catalog[target] == nil, mayUse, let ensureEngine {
            let engine = Engines.kind(of: target)
            // Splash runs one model: asked for the model it's now set to while still serving the old
            // one, it restarts on the new one.
            let splashSwitch = engine == .splash && target == SplashConfig.servedName(cfg.splash.model)
            let needsStart = splashSwitch ? true : !(await Self.engineUp(engine, cfg))
            if needsStart {
                Log.write("\(target) asked for while \(engine.label) \(splashSwitch ? "serves another model; switching it" : "is stopped; starting it")")
                if await ensureEngine(engine) {
                    catalog = await Engines.catalog(cfg)
                    available = catalog.keys.sorted()
                    allowed = kind == .local ? Set(available) : Set(Self.sharedModels(cfg, available: available))
                }
            }
        }
        // Backup model when the requested one isn't available.
        if !allowed.contains(target), let fb = cfg.preset(for: target).fallback, allowed.contains(fb) {
            Log.write("\(target) unavailable, using backup \(fb)")
            target = fb
        }
        guard allowed.contains(target) else {
            release()
            let hint = kind == .local ? "isn't available in \(Engines.kind(of: target).label)" : "is not a shared model (GET /v1/models lists them)"
            return respond(conn, 400, error: "\(requested.isEmpty ? "model" : requested) \(hint)", type: "not_found_error")
        }
        if req.path == "/v1/messages/count_tokens" {
            // Like Ollama: a local estimate (~4 characters per token) is all Claude needs here.
            release()
            let parts = ["system", "messages", "tools"].compactMap { payload[$0] }
            let text = (try? JSONSerialization.data(withJSONObject: parts)) ?? Data()
            return respondJSON(conn, 200, ["input_tokens": max(1, text.count / 4)])
        }
        let who = kind == .local ? "Claude (this Mac)" : (client?.name ?? "unknown")
        let backup = cfg.preset(for: target).fallback.flatMap { allowed.contains($0) && $0 != target ? $0 : nil }
        send(conn, req: req, payload: payload, target: target, backup: backup, catalog: catalog, cfg: cfg,
             who: who, address: address, requested: requested, release: release)
    }

    private func send(_ conn: NWConnection, req: HTTPRequest, payload original: [String: Any], target: String,
                      backup: String?, catalog: [String: Endpoint], cfg: AppConfig, who: String, address: String,
                      requested: String, release: @escaping () -> Void) {
        var payload = original
        let endpoint = catalog[target] ?? Engines.omlx(cfg)
        payload["model"] = endpoint.upstreamName(target)
        Presets.apply(cfg.preset(for: target), to: &payload, path: req.path)
        // The app asked for no thinking: also flip the chat template's switch, which these engines
        // obey even where they ignore Anthropic's thinking:disabled (llama.cpp does).
        if [.omlx, .splash, .llamacpp].contains(endpoint.engine), Presets.callerDisabledThinking(payload) {
            Presets.disableThinking(&payload)
        }
        guard var upstream = endpoint.request(req.path, timeout: 3600),
              let newBody = try? JSONSerialization.data(withJSONObject: payload) else {
            release(); return respond(conn, 500, error: "could not build the \(endpoint.engine.label) request", type: "api_error")
        }
        upstream.httpMethod = "POST"
        upstream.httpBody = newBody
        upstream.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if req.path.hasPrefix("/v1/messages") {
            upstream.setValue(req.headers["anthropic-version"] ?? "2023-06-01", forHTTPHeaderField: "anthropic-version")
            if let beta = req.headers["anthropic-beta"] { upstream.setValue(beta, forHTTPHeaderField: "anthropic-beta") }
        }
        if let accept = req.headers["accept"] { upstream.setValue(accept, forHTTPHeaderField: "Accept") }
        let started = Date()
        let stream = payload["stream"] as? Bool ?? false
        let path = req.path
        // If oMLX fails on this model before anything was sent, retry once on the backup model.
        let retry: (() -> Void)? = backup.map { b in { [weak self] in
            Log.write("\(target) failed in \(endpoint.engine.label), retrying on backup \(b)")
            self?.send(conn, req: req, payload: original, target: b, backup: nil, catalog: catalog, cfg: cfg, who: who,
                       address: address, requested: requested, release: release)
        } }
        StreamRelay(conn: conn, endpoint: endpoint, retryOnServerError: retry) { [weak self] status, sample, firstWordAt in
            guard let self else { return }
            release()
            let secs = Date().timeIntervalSince(started)
            let tokens = UsageStore.tokens(in: sample)
            let from = self.kind == .shared ? " from \(who) (\(address))" : ""
            Log.write("\(requested) -> \(target) [\(endpoint.engine.label)] \(path)\(from) status \(status) stream=\(stream) in=\(tokens.input) out=\(tokens.output) \(String(format: "%.1f", secs))s")
            UsageStore.shared.record(client: who, model: target, status: status, input: tokens.input, output: tokens.output, seconds: secs)
            self.onActivity?(Activity(date: Date(), client: who, address: address, model: target, path: path,
                                      status: status, inputTokens: tokens.input, outputTokens: tokens.output, seconds: secs,
                                      engine: endpoint.engine.rawValue, stream: stream,
                                      cachedTokens: UsageStore.cachedTokens(in: sample),
                                      firstWord: firstWordAt.map { $0.timeIntervalSince(started) }))
        }.start(upstream)
    }

    private func runControl(_ conn: NWConnection, _ action: String, _ args: [String: Any]) async {
        guard let control else { return respond(conn, 503, error: "not ready", type: "api_error") }
        let (status, obj) = await control(action, args)
        respondJSON(conn, status, obj)
    }

    static func engineUp(_ k: EngineKind, _ cfg: AppConfig) async -> Bool {
        await Engines.isUp(upstream: Engines.endpoint(k, cfg).upstream, engine: k)
    }

    // MARK: access control

    static func clientAddress(_ conn: NWConnection) -> String {
        if case .hostPort(let host, _) = conn.endpoint {
            var s = "\(host)"
            if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }   // drop IPv6 zone
            if s.hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }       // IPv4-mapped IPv6
            return s
        }
        return "unknown"
    }

    /// Loopback, RFC 1918, link-local, CGNAT (100.64/10, e.g. Tailscale) and IPv6 ULA / link-local.
    static func isPrivate(_ ip: String) -> Bool {
        if ip == "127.0.0.1" || ip == "::1" { return true }
        let p = ip.split(separator: ".").compactMap { Int($0) }
        if p.count == 4 {
            switch (p[0], p[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            case (100, 64...127): return true
            default: return false
            }
        }
        let lower = ip.lowercased()
        return lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd")
    }

    static func presentedKey(_ req: HTTPRequest) -> String {
        if let k = req.headers["x-api-key"], !k.isEmpty { return k }
        if let auth = req.headers["authorization"], auth.lowercased().hasPrefix("bearer ") {
            return String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    // MARK: responses

    func respondJSON(_ conn: NWConnection, _ status: Int, _ obj: Any) {
        let body = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
        sendRaw(conn, status, headers: ["Content-Type": "application/json"], body: body)
    }

    func respond(_ conn: NWConnection, _ status: Int, error message: String, type: String = "invalid_request_error") {
        respondJSON(conn, status, ["type": "error", "error": ["type": type, "message": message]])
    }

    private func sendRaw(_ conn: NWConnection, _ status: Int, headers: [String: String], body: Data) {
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        if status == 429 { head += "Retry-After: 5\r\n" }
        head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8); out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// Per-client limits: requests at once and requests per minute.
final class Limiter {
    private let lock = NSLock()
    private var active: [String: Int] = [:]
    private var recent: [String: [Date]] = [:]

    /// Returns nil when the request may go ahead (and counts it), or the reason it may not.
    func acquire(_ c: ShareClient) -> String? {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        var window = (recent[c.id] ?? []).filter { now.timeIntervalSince($0) < 60 }
        if c.maxConcurrent > 0, (active[c.id] ?? 0) >= c.maxConcurrent {
            return "\(c.name) already has \(c.maxConcurrent) request\(c.maxConcurrent == 1 ? "" : "s") running; try again shortly"
        }
        if c.perMinute > 0, window.count >= c.perMinute {
            return "\(c.name) has reached \(c.perMinute) requests this minute; try again shortly"
        }
        window.append(now)
        recent[c.id] = window
        active[c.id, default: 0] += 1
        return nil
    }

    func release(_ c: ShareClient) {
        lock.lock(); defer { lock.unlock() }
        active[c.id] = max(0, (active[c.id] ?? 1) - 1)
    }
}

/// Applies a model's preset to an outgoing request.
enum Presets {
    static let thinkingBudget = ["low": 1024, "medium": 4096, "high": 16384]

    static func apply(_ p: ModelPreset, to payload: inout [String: Any], path: String) {
        // Reply length: raise too-small limits so thinking can finish before the answer.
        let lengthKey = path == "/v1/responses" ? "max_output_tokens" : (path == "/v1/chat/completions" && payload["max_completion_tokens"] != nil ? "max_completion_tokens" : "max_tokens")
        if p.minOutputTokens > 0, path != "/v1/embeddings" {
            if let cur = payload[lengthKey] as? Int, cur < p.minOutputTokens { payload[lengthKey] = p.minOutputTokens }
        }
        if p.lockSampling && path != "/v1/embeddings" {
            for k in ["temperature", "top_p", "top_k", "min_p", "presence_penalty", "frequency_penalty",
                      "repetition_penalty", "repeat_penalty"] { payload[k] = nil }
        }
        if path != "/v1/embeddings" {
            let sampling: [(String, Any?)] = [("temperature", p.temperature), ("top_p", p.topP), ("top_k", p.topK),
                                              ("min_p", p.minP), ("presence_penalty", p.presencePenalty),
                                              ("repetition_penalty", p.repetitionPenalty)]
            for (key, value) in sampling { if let value, payload[key] == nil { payload[key] = value } }
        }

        guard p.thinking != "default" else { return }
        if p.thinking == "off" && path != "/v1/embeddings" { disableThinking(&payload) }
        switch path {
        case "/v1/messages":
            if p.thinking == "off" {
                payload["thinking"] = ["type": "disabled"]
            } else if let budget = thinkingBudget[p.thinking] {
                payload["thinking"] = ["type": "enabled", "budget_tokens": budget]
                let cur = payload["max_tokens"] as? Int ?? 0
                if cur <= budget { payload["max_tokens"] = budget + 2048 }   // budget must fit inside the limit
                // Engines that think in levels (Splash) ignore the budget and read Anthropic's effort,
                // which defaults to "high"; send the chosen level too.
                var oc = payload["output_config"] as? [String: Any] ?? [:]
                oc["effort"] = p.thinking
                payload["output_config"] = oc
            }
        case "/v1/chat/completions", "/v1/completions":
            payload["reasoning_effort"] = p.thinking == "off" ? "none" : p.thinking
        case "/v1/responses":
            payload["reasoning"] = ["effort": p.thinking == "off" ? "none" : p.thinking]
        default:
            break
        }
    }
}

extension Presets {
    /// Anthropic `thinking: {type: disabled}` or OpenAI `reasoning_effort: none`/`reasoning.effort: none`.
    static func callerDisabledThinking(_ payload: [String: Any]) -> Bool {
        if (payload["thinking"] as? [String: Any])?["type"] as? String == "disabled" { return true }
        if payload["reasoning_effort"] as? String == "none" { return true }
        return (payload["reasoning"] as? [String: Any])?["effort"] as? String == "none"
    }

    /// "Thinking off" that every model obeys. oMLX turns reasoning_effort "none" into "low" when a
    /// model's chat template has no "none" level (KAT-Coder, for one), so the model still thinks;
    /// the template switch stops it. Other template settings the caller sent are kept.
    static func disableThinking(_ payload: inout [String: Any]) {
        var kwargs = payload["chat_template_kwargs"] as? [String: Any] ?? [:]
        kwargs["enable_thinking"] = false
        payload["chat_template_kwargs"] = kwargs
    }
}

/// Parsed request line + headers (lower-cased keys).
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    var contentLength: Int { Int(headers["content-length"] ?? "") ?? 0 }

    init?(head: String) {
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        method = String(parts[0])
        path = String(parts[1].split(separator: "?").first ?? "")
        var h: [String: String] = [:]
        for line in lines {
            guard let i = line.firstIndex(of: ":") else { continue }
            h[line[..<i].lowercased()] = line[line.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        headers = h
    }
}

/// Streams one oMLX response back to the caller as it arrives (streaming and normal replies), and
/// keeps the start and end of the body so token counts can be read afterwards.
final class StreamRelay: NSObject, URLSessionDataDelegate {
    private let conn: NWConnection
    private let endpoint: Endpoint
    private let done: (Int, String, Date?) -> Void
    /// When the first real output (thinking or answer text) arrived.
    private var firstWordAt: Date?
    private var retry: (() -> Void)?
    private var session: URLSession?
    private var status = 0
    private var retried = false
    private var finished = false
    private var isEventStream = false
    private var isAnthropic = false
    private var head = Data()
    private var tail = Data()
    private var selfRef: StreamRelay?
    private var lastActivity = Date()
    private var idleChecks = 0
    private var watchdog: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "claudelocal.relay")
    private static let keep = 32 * 1024
    /// Silence long enough to ask oMLX whether it still has the request (prefill can be quiet).
    private static let quietLimit: TimeInterval = 60

    init(conn: NWConnection, endpoint: Endpoint, retryOnServerError: (() -> Void)? = nil, done: @escaping (Int, String, Date?) -> Void) {
        self.conn = conn
        self.endpoint = endpoint
        self.retry = retryOnServerError
        self.done = done
    }

    func start(_ request: URLRequest) {
        selfRef = self          // stay alive until the transfer finishes
        isAnthropic = request.url?.path.hasPrefix("/v1/messages") == true
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3600
        cfg.timeoutIntervalForResource = 6 * 3600
        let ops = OperationQueue()
        ops.underlyingQueue = queue
        ops.maxConcurrentOperationCount = 1
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: ops)
        session = s
        s.dataTask(with: request).resume()
        conn.stateUpdateHandler = { [weak self] state in
            if case .cancelled = state { self?.queue.async { self?.session?.invalidateAndCancel() } }   // caller hung up
        }
        startWatchdog()
    }

    /// oMLX drops requests without closing the connection when it reloads, restarts or unloads a
    /// model mid-request, and the caller would wait forever. After a quiet spell, ask oMLX whether
    /// anything is still running; if nothing is, end this request with a clear error.
    private func startWatchdog() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 30, repeating: 30)
        t.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            let ep = self.endpoint
            Task {
                let idle = await ep.looksIdle()
                self.queue.async {
                    guard !self.finished else { return }
                    // Three checks in a row (~90 s) with nothing running in oMLX and no real output:
                    // oMLX has dropped this request. One idle reading alone can be a model still loading.
                    self.idleChecks = idle ? self.idleChecks + 1 : 0
                    if Self.shouldAbort(idleChecks: self.idleChecks, quietFor: Date().timeIntervalSince(self.lastActivity)) {
                        let name = ep.engine.label
                        Log.write("request abandoned by \(name) (nothing running); ending it")
                        self.abort("\(name) dropped this request (it was reloaded, restarted, stopped or ran out of memory). Please try again.")
                    }
                }
            }
        }
        t.resume()
        watchdog = t
    }

    /// Three idle readings in a row (~90 s) and no real output for a minute.
    static func shouldAbort(idleChecks: Int, quietFor: TimeInterval) -> Bool {
        idleChecks >= 3 && quietFor > quietLimit
    }

    /// A streamed chunk carrying text (answer, thinking or tool arguments), not just a role or ping.
    static func hasOutput(_ data: Data) -> Bool {
        let t = String(decoding: data, as: UTF8.self)
        for key in ["\"content\":\"", "\"text\":\"", "\"thinking\":\"", "\"reasoning_content\":\"",
                    "\"reasoning\":\"", "\"partial_json\":\"", "\"delta\":\""] {
            var search = t[...]
            while let r = search.range(of: key) {
                if search[r.upperBound...].first.map({ $0 != "\"" }) == true { return true }
                search = search[r.upperBound...]
            }
        }
        return false
    }

    /// Keep-alive pings carry no output, so they don't count as the request making progress.
    static func isPing(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).allSatisfy { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            return l.isEmpty || l.hasPrefix(":") || l == "event: ping" || (l.hasPrefix("data:") && l.contains("\"ping\""))
        }
    }

    private func abort(_ message: String) {
        guard !finished else { return }
        if status == 0 {
            sendError(502, message)
            status = 502
        } else if isEventStream {
            let err = ["type": "error", "error": ["type": "api_error", "message": message]] as [String: Any]
            let json = String(decoding: (try? JSONSerialization.data(withJSONObject: isAnthropic ? err : ["error": err["error"]!])) ?? Data(), as: UTF8.self)
            let event = isAnthropic ? "event: error\ndata: \(json)\n\n" : "data: \(json)\n\n"
            conn.send(content: Data(event.utf8), completion: .contentProcessed { _ in })
        }
        retried = false
        session?.invalidateAndCancel()      // didCompleteWithError finishes up
    }

    private func sendError(_ code: Int, _ msg: String) {
        let body = (try? JSONSerialization.data(withJSONObject: ["type": "error", "error": ["type": "api_error", "message": msg]])) ?? Data()
        var out = Data("HTTP/1.1 \(code) \(HTTPURLResponse.localizedString(forStatusCode: code).capitalized)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in })
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lastActivity = Date()
        let http = response as? HTTPURLResponse
        status = http?.statusCode ?? 502
        if status >= 500, let retry {
            // Nothing has been sent to the caller yet: hand over to the backup model.
            retried = true
            self.retry = nil
            completionHandler(.cancel)
            retry()
            return
        }
        let type = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/json"
        isEventStream = type.contains("event-stream")
        var h = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        h += "Content-Type: \(type)\r\n"
        h += "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"   // body runs until we close
        conn.send(content: Data(h.utf8), completion: .contentProcessed { _ in })
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if firstWordAt == nil, isEventStream, Self.hasOutput(data) { firstWordAt = Date() }
        if !Self.isPing(data) { lastActivity = Date() }
        conn.send(content: data, completion: .contentProcessed { _ in })
        if head.count < Self.keep { head.append(data.prefix(Self.keep - head.count)) }
        tail.append(data)
        if tail.count > Self.keep { tail = tail.suffix(Self.keep) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        finished = true
        watchdog?.cancel()
        watchdog = nil
        defer { session.finishTasksAndInvalidate(); selfRef = nil }
        if retried { return }    // the backup request owns the connection now
        if status == 0 {
            sendError(502, "\(endpoint.engine.label) is not running or not reachable")
            status = 502
        }
        conn.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [conn] _ in conn.cancel() })
        let sample = String(decoding: head, as: UTF8.self) + "\n" + String(decoding: tail, as: UTF8.self)
        done(status, sample, firstWordAt)          // nil for a reply sent in one piece
    }
}
