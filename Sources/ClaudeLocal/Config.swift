import Foundation
import Security

/// One of Claude Desktop's fixed model ids. Claude only asks for these, so the gateway shows
/// each slot under the name of the oMLX model assigned to it (same slots as Ollama 0.40).
struct ClaudeSlot: Identifiable, Hashable {
    let id: String
    let label: String
    let family: String
    let createdAt: String
    let isFamilyDefault: Bool
}

enum Slots {
    static let all: [ClaudeSlot] = [
        ClaudeSlot(id: "claude-fable-5", label: "Fable 5", family: "fable", createdAt: "2026-06-09T00:00:00Z", isFamilyDefault: true),
        ClaudeSlot(id: "claude-opus-5", label: "Opus 5", family: "opus", createdAt: "2026-07-24T00:00:00Z", isFamilyDefault: true),
        ClaudeSlot(id: "claude-sonnet-5", label: "Sonnet 5", family: "sonnet", createdAt: "2026-06-30T00:00:00Z", isFamilyDefault: true),
        ClaudeSlot(id: "claude-haiku-4-5-20251001", label: "Haiku 4.5", family: "haiku", createdAt: "2025-10-01T00:00:00Z", isFamilyDefault: true),
        ClaudeSlot(id: "claude-sonnet-4-6", label: "Sonnet 4.6", family: "sonnet", createdAt: "2025-11-18T00:00:00Z", isFamilyDefault: false),
    ]
}

/// One person or computer allowed to use the shared models. Each has its own key and limits.
struct ShareClient: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var key: String = AppConfig.newShareKey()
    var enabled: Bool = true
    /// Requests this client may run at the same time (0 = no limit).
    var maxConcurrent: Int = 2
    /// Requests per minute (0 = no limit).
    var perMinute: Int = 0
    var created: Date = Date()
}

/// Per-model defaults applied by the gateway (both the Claude gateway and the shared one).
struct ModelPreset: Codable, Equatable {
    /// "default" leaves the caller's choice alone; "off", "low", "medium", "high" override it.
    var thinking: String = "default"
    /// Raise a request's reply-length limit to at least this (0 = leave it). Stops replies being cut
    /// off mid-thinking, which makes oMLX return the unfinished thinking as the answer.
    var minOutputTokens: Int = 4096
    /// Used only when the caller doesn't set a temperature (nil = leave it).
    var temperature: Double? = nil
    /// Model to use instead when this one isn't loaded or oMLX fails on it (nil = none).
    var fallback: String? = nil
    // Sampling defaults, used only when the caller doesn't set them (nil = leave it). oMLX models
    // keep theirs in oMLX; Splash has no per-model settings, so this is where its models are tuned.
    var topP: Double? = nil
    var topK: Int? = nil
    var minP: Double? = nil
    var presencePenalty: Double? = nil
    var repetitionPenalty: Double? = nil
    /// Ignore the sampling values apps send, so the tuned ones always apply (scripts and tools that
    /// send their own temperature made thinking models loop).
    var lockSampling: Bool = false

    init() {}

    /// Sets any sampling value (an untuned model runs on the engine's generic defaults).
    var hasSampling: Bool {
        temperature != nil || topP != nil || topK != nil || minP != nil || presencePenalty != nil || repetitionPenalty != nil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        thinking = (try? c.decode(String.self, forKey: .thinking)) ?? "default"
        minOutputTokens = (try? c.decode(Int.self, forKey: .minOutputTokens)) ?? 4096
        temperature = try? c.decode(Double.self, forKey: .temperature)
        fallback = try? c.decode(String.self, forKey: .fallback)
        topP = try? c.decode(Double.self, forKey: .topP)
        topK = try? c.decode(Int.self, forKey: .topK)
        minP = try? c.decode(Double.self, forKey: .minP)
        presencePenalty = try? c.decode(Double.self, forKey: .presencePenalty)
        repetitionPenalty = try? c.decode(Double.self, forKey: .repetitionPenalty)
        lockSampling = (try? c.decode(Bool.self, forKey: .lockSampling)) ?? false
    }
}

/// Settings for an engine LLM Switcher drives from outside (Ollama, LM Studio, llama.cpp).
struct EngineSettings: Codable, Equatable {
    /// Listed in the menu and asked for its models. Off for engines that aren't installed.
    var enabled: Bool = false
    var port: Int = 0
    /// Key LLM Switcher starts llama.cpp with (Ollama and LM Studio take none on loopback).
    var key: String = "sk-" + AppConfig.newShareKey().dropFirst(3)
    /// Ollama: context window it loads models with (OLLAMA_CONTEXT_LENGTH; 0 = Ollama's default).
    var contextLength: Int = 65536
    /// llama.cpp: folder of GGUF models ("" = its Hugging Face cache) and an optional presets file.
    var modelsDir: String = ""
    var presetFile: String = ""
    /// llama.cpp: free the model's memory after this long idle (it reloads on the next request).
    var sleepIdleMinutes: Int = 30

    init(port: Int = 0) { self.port = port }

    init(from decoder: Decoder) throws {
        let d = EngineSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        port = (try? c.decode(Int.self, forKey: .port)) ?? d.port
        key = (try? c.decode(String.self, forKey: .key)) ?? d.key
        contextLength = (try? c.decode(Int.self, forKey: .contextLength)) ?? d.contextLength
        modelsDir = (try? c.decode(String.self, forKey: .modelsDir)) ?? d.modelsDir
        presetFile = (try? c.decode(String.self, forKey: .presetFile)) ?? d.presetFile
        sleepIdleMinutes = (try? c.decode(Int.self, forKey: .sleepIdleMinutes)) ?? d.sleepIdleMinutes
    }
}

/// The Splash engine (github.com/incoai/splash): one model per server, started and stopped by
/// LLM Switcher on its own port. Its key is made here and handed to Splash in its environment.
struct SplashConfig: Codable, Equatable {
    var port: Int = 8100
    /// Hugging Face id, optionally with a GGUF variant after ':' (Splash only takes these).
    var model: String = ""
    var autoStart: Bool = false
    /// Splash's context limit in tokens (0 = automatic, the model's window when memory holds it).
    var maxContext: Int = 0
    var kvFormat: String = "int8"
    /// "" = the model template's default; else none/minimal/low/medium/high/xhigh/max.
    var reasoningEffort: String = ""
    /// Unload the weights after this long without requests: "off", "10m", "30m", "1h" …
    var idleRelease: String = "off"
    /// Metal memory budget in GB (0 = automatic).
    var maxMemoryGB: Int = 0
    /// SSD prompt cache in GB (0 = off), kept across restarts when persistentCache.
    var cacheDiskGB: Int = 0
    var persistentCache: Bool = false
    var languageOnly: Bool = false
    /// Stop Splash after this many minutes with no requests while Claude isn't using it (0 = never).
    var idleStopMinutes: Int = 10
    var key: String = "sk-" + AppConfig.newShareKey().dropFirst(3)

    init() {}

    init(from decoder: Decoder) throws {
        let d = SplashConfig()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = (try? c.decode(Int.self, forKey: .port)) ?? d.port
        model = (try? c.decode(String.self, forKey: .model)) ?? d.model
        autoStart = (try? c.decode(Bool.self, forKey: .autoStart)) ?? d.autoStart
        maxContext = (try? c.decode(Int.self, forKey: .maxContext)) ?? d.maxContext
        kvFormat = (try? c.decode(String.self, forKey: .kvFormat)) ?? d.kvFormat
        reasoningEffort = (try? c.decode(String.self, forKey: .reasoningEffort)) ?? d.reasoningEffort
        idleRelease = (try? c.decode(String.self, forKey: .idleRelease)) ?? d.idleRelease
        maxMemoryGB = (try? c.decode(Int.self, forKey: .maxMemoryGB)) ?? d.maxMemoryGB
        cacheDiskGB = (try? c.decode(Int.self, forKey: .cacheDiskGB)) ?? d.cacheDiskGB
        persistentCache = (try? c.decode(Bool.self, forKey: .persistentCache)) ?? d.persistentCache
        languageOnly = (try? c.decode(Bool.self, forKey: .languageOnly)) ?? d.languageOnly
        idleStopMinutes = (try? c.decode(Int.self, forKey: .idleStopMinutes)) ?? d.idleStopMinutes
        key = (try? c.decode(String.self, forKey: .key)) ?? d.key
    }

    var upstream: String { "http://127.0.0.1:\(port)" }

    /// Splash runs one model, so every Splash slot that has a model uses the same one.
    static func unifiedPicks(_ picks: [String: String], model served: String) -> [String: String] {
        guard !served.isEmpty else { return picks }
        return picks.mapValues { $0.isEmpty ? $0 : served }
    }

    /// The name the model is served and listed under: "splash/" + the repo name, so it never
    /// collides with the same weights in oMLX.
    static func servedName(_ model: String) -> String {
        guard !model.isEmpty else { return "" }
        let repo = model.split(separator: ":").first.map(String.init) ?? model
        return "splash/" + (repo.split(separator: "/").last.map(String.init) ?? repo)
    }
}

/// Settings shared by the app, the gateways and the `claude-omlx` / `claude-local` terminal
/// launchers. Stored at ~/Library/Application Support/ClaudeLocal/config.json (owner-only).
struct AppConfig: Codable, Equatable {
    var port: Int = 11436
    var upstream: String = "http://127.0.0.1:8000"
    var slots: [String: String] = [:]
    var autoMode: Bool = false
    // Network sharing (off by default). Client keys are separate from oMLX's own key, so people on
    // the network can use models but can't manage oMLX. nil sharedModels = share every chat model.
    var shareEnabled: Bool = false
    var sharePort: Int = 11437
    var clients: [ShareClient] = []
    var sharedModels: [String]? = nil
    var presets: [String: ModelPreset] = [:]
    var bonjour: Bool = true
    var tlsEnabled: Bool = false
    var splash = SplashConfig()
    /// The engine Claude uses. `slots` always holds that engine's picks (the gateway and the
    /// launchers read it); each engine's own picks are kept in `engineSlots` while it's not chosen.
    var engine: EngineKind = .omlx
    var engineSlots: [String: [String: String]] = [:]
    /// Ollama, LM Studio and llama.cpp settings, by EngineKind raw value.
    var engines: [String: EngineSettings] = [:]
    /// What to do when a model about to load won't fit beside other engines' loaded models.
    var memoryGuard: MemoryGuard.Mode = .unload

    /// An external engine's settings (defaults, with its usual port, until changed).
    func engine(_ kind: EngineKind) -> EngineSettings {
        engines[kind.rawValue] ?? EngineSettings(port: kind.defaultPort)
    }

    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/ClaudeLocal", isDirectory: true)
    static let url = directory.appendingPathComponent("config.json")

    init() {
        for k in EngineKind.external { engines[k.rawValue] = EngineSettings(port: k.defaultPort) }
    }

    // Lenient decoding: older files lack newer keys, and a single bad field mustn't lose the rest.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = (try? c.decode(Int.self, forKey: .port)) ?? 11436
        upstream = (try? c.decode(String.self, forKey: .upstream)) ?? "http://127.0.0.1:8000"
        slots = ((try? c.decode([String: String].self, forKey: .slots)) ?? [:]).filter { !$0.value.isEmpty }
        autoMode = (try? c.decode(Bool.self, forKey: .autoMode)) ?? false
        shareEnabled = (try? c.decode(Bool.self, forKey: .shareEnabled)) ?? false
        sharePort = (try? c.decode(Int.self, forKey: .sharePort)) ?? 11437
        clients = (try? c.decode([ShareClient].self, forKey: .clients)) ?? []
        sharedModels = try? c.decode([String].self, forKey: .sharedModels)
        presets = (try? c.decode([String: ModelPreset].self, forKey: .presets)) ?? [:]
        bonjour = (try? c.decode(Bool.self, forKey: .bonjour)) ?? true
        tlsEnabled = (try? c.decode(Bool.self, forKey: .tlsEnabled)) ?? false
        splash = (try? c.decode(SplashConfig.self, forKey: .splash)) ?? SplashConfig()
        engine = (try? c.decode(EngineKind.self, forKey: .engine)) ?? .omlx
        engineSlots = (try? c.decode([String: [String: String]].self, forKey: .engineSlots)) ?? [:]
        engines = (try? c.decode([String: EngineSettings].self, forKey: .engines)) ?? [:]
        memoryGuard = (try? c.decode(MemoryGuard.Mode.self, forKey: .memoryGuard)) ?? .unload
    }

    /// oMLX's port, from the upstream URL.
    var omlxPort: Int { URLComponents(string: upstream)?.port ?? 8000 }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: url) else {
            // First run: write the file at once so its generated keys stay the same everywhere.
            let fresh = AppConfig()
            fresh.save()
            return fresh
        }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var cfg = (try? dec.decode(AppConfig.self, from: data)) ?? AppConfig()
        // Migrate the single share key from the first sharing version into a client.
        if cfg.clients.isEmpty,
           let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let legacy = raw["shareKey"] as? String, !legacy.isEmpty {
            cfg.clients = [ShareClient(name: "Original key", key: legacy, maxConcurrent: 0)]
            cfg.save()
        }
        // Keys (Splash's, each external engine's) are made on first load; save them so every
        // later read sees the same ones.
        var missing = false
        if let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            missing = (raw["splash"] as? [String: Any])?["key"] == nil
            let engines = raw["engines"] as? [String: [String: Any]] ?? [:]
            for k in EngineKind.external where engines[k.rawValue]?["key"] == nil {
                // Keep whatever else was set; only the key is new.
                var s = cfg.engines[k.rawValue] ?? EngineSettings(port: k.defaultPort)
                s.key = EngineSettings().key
                cfg.engines[k.rawValue] = s
                missing = true
            }
        }
        if missing { cfg.save() }
        return cfg
    }

    func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        var copy = self
        copy.slots = slots.filter { !$0.value.isEmpty }
        if let data = try? enc.encode(copy) {
            try? data.write(to: Self.url, options: .atomic)
            // The file holds client keys: owner-only.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.url.path)
        }
    }

    func preset(for model: String) -> ModelPreset { presets[model] ?? ModelPreset() }

    func client(forKey key: String) -> ShareClient? {
        guard !key.isEmpty else { return nil }
        return clients.first { constantTimeEqual($0.key, key) }
    }

    /// A new random share key, e.g. "cl-" + 32 URL-safe characters.
    static func newShareKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let b64 = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "cl-" + b64
    }
}

func constantTimeEqual(_ x: String, _ y: String) -> Bool {
    let a = Array(x.utf8), b = Array(y.utf8)
    guard a.count == b.count else { return false }
    return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
}

enum Log {
    private static let queue = DispatchQueue(label: "claudelocal.log")
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ClaudeLocal/gateway.log")

    static func write(_ message: String) {
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = Data("\(stamp) \(message)\n".utf8)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line); try? h.close()
            } else {
                try? line.write(to: url)
            }
        }
    }
}
