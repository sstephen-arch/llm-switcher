import Foundation

/// The inference servers LLM Switcher can route to. Every model name maps to one of them, so
/// Claude's slots, sharing, presets and the review loop work the same whichever engine runs it.
enum EngineKind: String, Codable, CaseIterable {
    case omlx, splash, ollama, lmstudio, llamacpp

    var label: String {
        switch self {
        case .omlx: return "oMLX"
        case .splash: return "Splash"
        case .ollama: return "Ollama"
        case .lmstudio: return "LM Studio"
        case .llamacpp: return "llama.cpp"
        }
    }

    /// Models of this engine are listed as "<prefix>/<its own name>", so names never collide
    /// across engines. oMLX keeps plain names (what existing slots and shared clients use).
    var prefix: String? { self == .omlx ? nil : rawValue }

    /// The engines LLM Switcher drives through `ExternalEngine` (oMLX and Splash have their own code).
    static let external: [EngineKind] = [.ollama, .lmstudio, .llamacpp]

    var defaultPort: Int {
        switch self {
        case .omlx: return 8000
        case .splash: return 8100
        case .ollama: return 11434
        case .lmstudio: return 1234
        case .llamacpp: return 8300
        }
    }
}

/// Where to send requests for one model.
struct Endpoint: Equatable {
    let engine: EngineKind
    let upstream: String
    let key: String

    func request(_ path: String, timeout: TimeInterval = 5) -> URLRequest? {
        guard let url = URL(string: upstream + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return req
    }

    /// The name the engine itself knows the model by. Splash serves our "splash/…" alias; the
    /// external engines get their own names back.
    func upstreamName(_ name: String) -> String {
        guard EngineKind.external.contains(engine), let p = engine.prefix, name.hasPrefix(p + "/") else { return name }
        return String(name.dropFirst(p.count + 1))
    }

    /// True when the server looks to have nothing running for us (used to end requests it dropped).
    func looksIdle() async -> Bool {
        switch engine {
        case .omlx: return await OMLXAdmin.looksIdle(upstream: upstream)
        // The others answer or close the connection themselves; only a server that's gone counts as idle.
        default: return !(await Engines.isUp(upstream: upstream, engine: engine))
        }
    }
}

enum Engines {
    static func omlx(_ cfg: AppConfig) -> Endpoint { Endpoint(engine: .omlx, upstream: cfg.upstream, key: OMLX.apiKey()) }
    static func splash(_ cfg: AppConfig) -> Endpoint { Endpoint(engine: .splash, upstream: cfg.splash.upstream, key: cfg.splash.key) }

    static func endpoint(_ kind: EngineKind, _ cfg: AppConfig) -> Endpoint {
        switch kind {
        case .omlx: return omlx(cfg)
        case .splash: return splash(cfg)
        default:
            let s = cfg.engine(kind)
            return Endpoint(engine: kind, upstream: "http://127.0.0.1:\(s.port)", key: s.key)
        }
    }

    /// Every chat model the engines can serve now, by name. oMLX wins a name clash (the others
    /// are prefixed, so there shouldn't be one).
    static func catalog(_ cfg: AppConfig) async -> [String: Endpoint] {
        async let o = OMLX.models(upstream: cfg.upstream)
        async let s = Splash.models(cfg.splash)
        async let x = externalModels(cfg)
        var out: [String: Endpoint] = [:]
        for (kind, names) in await x {
            let ep = endpoint(kind, cfg)
            for n in names { out[(kind.prefix ?? "") + "/" + n] = ep }
        }
        let sp = splash(cfg)
        for m in await s { out[m] = sp }
        let om = omlx(cfg)
        for m in await o { out[m] = om }
        return out
    }

    private static func externalModels(_ cfg: AppConfig) async -> [(EngineKind, [String])] {
        await withTaskGroup(of: (EngineKind, [String]).self) { group in
            for kind in EngineKind.external where cfg.engine(kind).enabled {
                group.addTask { (kind, await ExternalEngines.models(kind, cfg)) }
            }
            var out: [(EngineKind, [String])] = []
            for await r in group { out.append(r) }
            return out
        }
    }

    /// The engine a model name belongs to, from its prefix (plain names are oMLX's).
    static func kind(of model: String) -> EngineKind {
        for k in EngineKind.allCases where k.prefix != nil && model.hasPrefix(k.prefix! + "/") { return k }
        return .omlx
    }

    /// The engine serving `model`; when it isn't listed now, the engine its name belongs to, so a
    /// stopped engine reports "<engine> is not running" instead of oMLX not knowing the name.
    static func endpoint(for model: String, _ cfg: AppConfig) async -> Endpoint {
        if let hit = await catalog(cfg)[model] { return hit }
        return endpoint(kind(of: model), cfg)
    }

    static func isUp(upstream: String, engine: EngineKind) async -> Bool {
        let path: String
        switch engine {
        case .ollama: path = "/api/version"
        case .lmstudio: path = "/v1/models"
        default: path = "/health"
        }
        guard let url = URL(string: upstream + path),
              let (_, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 2)),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return false }
        // LM Studio may ask for its own API token (401/403); that still means it's LM Studio, up.
        return code == 200 || (engine == .lmstudio && (code == 401 || code == 403))
    }
}
