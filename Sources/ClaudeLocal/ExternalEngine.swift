import Foundation

/// Ollama, LM Studio and llama.cpp: finding them, asking for their models, and how to start them.
/// All three speak OpenAI chat, OpenAI Responses and Anthropic /v1/messages themselves, and load a
/// model on its first request, so LLM Switcher only starts the server and passes requests through.
enum ExternalEngines {
    static func binaryCandidates(_ kind: EngineKind) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        switch kind {
        case .ollama: return ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"]
        case .lmstudio: return ["\(home)/.lmstudio/bin/lms", "/opt/homebrew/bin/lms", "/usr/local/bin/lms"]
        case .llamacpp: return ["/opt/homebrew/bin/llama-server", "/usr/local/bin/llama-server"]
        default: return []
        }
    }

    /// The program LLM Switcher runs (nil = not installed). A broken link doesn't count.
    static func binary(_ kind: EngineKind) -> String? {
        binaryCandidates(kind).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func installHint(_ kind: EngineKind) -> String {
        switch kind {
        case .ollama: return "brew install ollama   (or the app from ollama.com)"
        case .lmstudio: return "Install LM Studio from lmstudio.ai and open it once (that sets up its lms tool)."
        case .llamacpp: return "brew install llama.cpp"
        default: return ""
        }
    }

    /// The engine's own model names (installed ones; each loads on its first request).
    static func models(_ kind: EngineKind, _ cfg: AppConfig) async -> [String] {
        let ep = Engines.endpoint(kind, cfg)
        let path = kind == .ollama ? "/api/tags" : "/v1/models"
        guard let req = ep.request(path, timeout: 2),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        let names: [String]
        if kind == .ollama {
            names = (obj["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        } else {
            names = (obj["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        }
        // Embedding models can't chat; leave them out of Claude's and the sharing lists.
        return names.filter { !$0.localizedCaseInsensitiveContains("embed") }.sorted()
    }

    /// Models already downloaded for the engine, read from its own cache without starting it
    /// (names as the engine reports them). LM Studio's are learned the first time it runs.
    static func downloadedModels(_ kind: EngineKind) -> [String] {
        switch kind {
        case .llamacpp:
            // `llama-server --cache-list` prints "   1. org/Repo-GGUF:QUANT".
            guard let bin = binary(kind) else { return [] }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = ["--cache-list"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return [] }
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            return text.split(separator: "\n").compactMap { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let dot = t.firstIndex(of: "."), Int(t[..<dot]) != nil else { return nil }
                return t[t.index(after: dot)...].trimmingCharacters(in: .whitespaces)
            }
        case .ollama:
            // ~/.ollama/models/manifests/registry.ollama.ai/library/<name>/<tag>
            let lib = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".ollama/models/manifests/registry.ollama.ai/library")
            let fm = FileManager.default
            return ((try? fm.contentsOfDirectory(atPath: lib.path)) ?? []).flatMap { name in
                ((try? fm.contentsOfDirectory(atPath: lib.appendingPathComponent(name).path)) ?? []).map { "\(name):\($0)" }
            }.filter { !$0.localizedCaseInsensitiveContains("embed") }
        default:
            return []
        }
    }

    /// Words that identify the engine's server process in `ps` (to tell it from something else).
    static func processMarker(_ kind: EngineKind) -> String {
        switch kind {
        case .ollama: return "ollama"
        case .lmstudio: return "lm studio"
        case .llamacpp: return "llama-server"
        default: return kind.rawValue
        }
    }
}

/// Starts, watches and stops one external engine.
@MainActor
final class ExternalEngine: ObservableObject {
    enum Phase: Equatable { case stopped, starting, ready, failed(String) }

    let kind: EngineKind
    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var installed: Bool
    /// True when the running server was started by someone else (we can use it, not stop it).
    @Published private(set) var external = false

    private var process: Process?
    /// A llama.cpp server from an earlier run of LLM Switcher: it holds our key, so it's ours to stop.
    private var adoptedPid: pid_t?
    /// The start in progress: a second caller waits for it instead of starting another copy.
    private var starting: Task<Bool, Never>?
    private var stopping: Task<Void, Never>?

    init(_ kind: EngineKind) {
        self.kind = kind
        installed = ExternalEngines.binary(kind) != nil
    }

    var isUp: Bool { phase == .ready }
    /// LM Studio's server was started by our `lms server start` (so Stop may stop it).
    private var startedLMStudio = false
    var logURL: URL { Log.url.deletingLastPathComponent().appendingPathComponent("\(kind.rawValue).log") }

    var label: String {
        switch phase {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .ready: return external ? "Running (started outside LLM Switcher)" : "Running"
        case .failed(let s): return s
        }
    }

    func refresh(_ cfg: AppConfig) async {
        installed = ExternalEngines.binary(kind) != nil
        if case .starting = phase { return }
        if stopping != nil { return }          // still answering while it shuts down
        let up = await Engines.isUp(upstream: Engines.endpoint(kind, cfg).upstream, engine: kind)
        if up {
            if phase != .ready { external = await !isOurs(cfg) }
            phase = .ready
        } else if phase == .ready {
            phase = .failed("\(kind.label) stopped unexpectedly. See its log.")
        }
    }

    /// Starts the engine and waits until it answers. False when it couldn't. Calls made while a
    /// start is under way share it; a stop under way finishes first.
    func start(_ cfg: AppConfig) async -> Bool {
        if phase == .ready { return true }
        if let starting { return await starting.value }
        let t = Task { () -> Bool in
            await stopping?.value
            return await doStart(cfg)
        }
        starting = t
        phase = .starting
        let ok = await t.value
        starting = nil
        return ok
    }

    private func doStart(_ cfg: AppConfig) async -> Bool {
        let s = cfg.engine(kind)
        let ep = Engines.endpoint(kind, cfg)
        if await Engines.isUp(upstream: ep.upstream, engine: kind) { external = await !isOurs(cfg); phase = .ready; return true }
        guard let bin = ExternalEngines.binary(kind) else {
            phase = .failed("\(kind.label) isn't installed. \(ExternalEngines.installHint(kind))"); return false
        }
        if let owner = await Ports.listener(s.port) {
            phase = .failed("Port \(s.port) is already used by \(owner.command) (pid \(owner.pid)). Pick another port.")
            return false
        }
        do {
            switch kind {
            case .lmstudio:
                // lms starts LM Studio's server in the background and returns.
                try await runShort(bin, ["server", "start", "--port", String(s.port)])
                startedLMStudio = true
            case .ollama:
                var env = ["OLLAMA_HOST": "127.0.0.1:\(s.port)"]
                if s.contextLength > 0 { env["OLLAMA_CONTEXT_LENGTH"] = String(s.contextLength) }
                try run(bin, ["serve"], env: env)
            case .llamacpp:
                var args = ["--host", "127.0.0.1", "--port", String(s.port), "--jinja"]
                if !s.modelsDir.isEmpty { args += ["--models-dir", s.modelsDir] }
                if !s.presetFile.isEmpty { args += ["--models-preset", s.presetFile] }
                if s.sleepIdleMinutes > 0 { args += ["--sleep-idle-seconds", String(s.sleepIdleMinutes * 60)] }
                // The key goes in the environment so it never shows in `ps`.
                try run(bin, args, env: ["LLAMA_API_KEY": s.key])
            default:
                return false
            }
        } catch {
            phase = .failed("Couldn't start \(kind.label): \(error.localizedDescription)")
            return false
        }
        for _ in 0..<120 {
            if await Engines.isUp(upstream: ep.upstream, engine: kind) {
                external = false
                phase = .ready
                Log.write("\(kind.rawValue) ready on port \(s.port)")
                return true
            }
            if let p = process, !p.isRunning { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        phase = .failed("\(kind.label) didn't start. See its log.")
        return false
    }

    /// Stops a server LLM Switcher started. One started elsewhere is only let go, never killed.
    func stop(_ cfg: AppConfig) async {
        let t = Task { await doStop() }
        stopping = t
        await t.value
        stopping = nil
    }

    private func doStop() async {
        let wasExternal = external
        phase = .stopped
        external = false
        if wasExternal { return }
        if kind == .lmstudio, startedLMStudio, let bin = ExternalEngines.binary(kind) {
            startedLMStudio = false
            try? await runShort(bin, ["server", "stop"])
            return
        }
        // Only a process we started: never a pid found by port, which may be someone else's now.
        let pid: pid_t
        if let p = process, p.isRunning { pid = p.processIdentifier }
        else if let a = adoptedPid { pid = a }
        else { process = nil; return }
        process = nil
        adoptedPid = nil
        Log.write("stopping \(kind.rawValue) pid \(pid)")
        kill(pid, SIGTERM)
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        kill(pid, SIGKILL)
    }

    /// Called when LLM Switcher quits: a server it started can't be reached without the gateway.
    func stopNow() {
        if let p = process, p.isRunning { kill(p.processIdentifier, SIGTERM) }
    }

    /// Started by LLM Switcher: our own process, or a llama.cpp that refuses no key but accepts ours
    /// (only we know it). Sets adoptedPid for the latter so Stop works after an app restart.
    private func isOurs(_ cfg: AppConfig) async -> Bool {
        if let p = process, p.isRunning { return true }
        guard kind == .llamacpp else { return false }
        let ep = Engines.endpoint(kind, cfg)
        let anon = Endpoint(engine: kind, upstream: ep.upstream, key: "")
        guard let withKey = ep.request("/v1/models", timeout: 2), let without = anon.request("/v1/models", timeout: 2),
              let (_, r1) = try? await URLSession.shared.data(for: withKey),
              let (_, r2) = try? await URLSession.shared.data(for: without),
              (r1 as? HTTPURLResponse)?.statusCode == 200, (r2 as? HTTPURLResponse)?.statusCode == 401,
              let owner = await Ports.listener(cfg.engine(kind).port), owner.command == kind.label else { return false }
        adoptedPid = owner.pid
        return true
    }

    /// A short command (lms server start/stop), run off the main thread.
    private func runShort(_ bin: String, _ args: [String]) async throws {
        let url = logURL, name = kind.rawValue
        try await Task.detached {
            let (p, log) = try Self.process(bin, args, env: [:], log: url, name: name)
            try p.run()
            p.waitUntilExit()
            try? log.close()
        }.value
    }

    /// Starts the engine's server program, which keeps running.
    private func run(_ bin: String, _ args: [String], env: [String: String]) throws {
        let (p, _) = try Self.process(bin, args, env: env, log: logURL, name: kind.rawValue)
        try p.run()
        process = p
        Log.write("\(kind.rawValue) started pid \(p.processIdentifier)")
    }

    /// A process for the engine's program, its output appended to the engine's log.
    nonisolated private static func process(_ bin: String, _ args: [String], env extra: [String: String],
                                            log url: URL, name: String) throws -> (Process, FileHandle) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        let log = try FileHandle(forWritingTo: url)
        log.seekToEndOfFile()
        log.write(Data("--- \(name) \(args.joined(separator: " "))\n".utf8))
        p.standardOutput = log
        p.standardError = log
        return (p, log)
    }
}
