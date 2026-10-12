import Foundation

/// The ports LLM Switcher and the engines listen on, and who is using them, so two servers never
/// try to share one (oMLX and Splash both default to 8000).
enum Ports {
    enum Service: String, CaseIterable, Identifiable {
        case gateway, sharing, omlx, splash, ollama, lmstudio, llamacpp
        var id: String { rawValue }

        /// The engine this port belongs to (nil for LLM Switcher's own two).
        var engine: EngineKind? { EngineKind(rawValue: rawValue) }

        var label: String {
            switch self {
            case .gateway: return "Claude gateway (this Mac)"
            case .sharing: return "Network sharing"
            case .omlx, .splash, .ollama, .lmstudio, .llamacpp: return engine!.label
            }
        }
    }

    static func port(_ s: Service, _ cfg: AppConfig) -> Int {
        switch s {
        case .gateway: return cfg.port
        case .sharing: return cfg.sharePort
        case .omlx: return cfg.omlxPort
        case .splash: return cfg.splash.port
        case .ollama, .lmstudio, .llamacpp: return cfg.engine(s.engine!).port
        }
    }

    /// Why `port` can't be used for `service`, or nil when it's fine.
    static func clash(for service: Service, port: Int, _ cfg: AppConfig) -> String? {
        guard (1024...65535).contains(port) else { return "Use a port between 1024 and 65535." }
        for other in Service.allCases where other != service && Self.port(other, cfg) == port {
            return "Port \(port) is already set for \(other.label)."
        }
        return nil
    }

    struct Listener: Equatable { let pid: Int32; let command: String }

    /// The process listening on a TCP port on this Mac, if any (via lsof).
    static func listener(_ port: Int) async -> Listener? {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var pid: Int32 = 0, cmd = ""
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                if line.hasPrefix("p"), pid == 0 { pid = Int32(line.dropFirst()) ?? 0 }
                if line.hasPrefix("c"), cmd.isEmpty { cmd = String(line.dropFirst()) }
            }
            guard pid > 0 else { return nil }
            return Listener(pid: pid, command: friendlyName(pid: pid, fallback: cmd))
        }.value
    }

    /// lsof shows both engines as "python3.x"; their full command lines tell them apart.
    private static func friendlyName(pid: Int32, fallback: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", String(pid), "-o", "command="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return fallback }
        let line = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).lowercased()
        p.waitUntilExit()
        if line.contains("splash") { return "Splash" }
        if line.contains("omlx") { return "oMLX" }
        if line.contains("llama-server") { return EngineKind.llamacpp.label }
        if line.contains("ollama") { return EngineKind.ollama.label }
        if line.contains("lm studio") || line.contains("lmstudio") || line.contains("llmster") { return EngineKind.lmstudio.label }
        if pid == getpid() { return "LLM Switcher" }
        return fallback
    }

    /// Changes oMLX's own port in ~/.omlx/settings.json (oMLX reads it when it starts).
    static func setOMLXPort(_ port: Int) throws {
        let data = try Data(contentsOf: OMLX.settingsURL)
        guard var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "LLMSwitcher", code: 1, userInfo: [NSLocalizedDescriptionKey: "oMLX's settings file couldn't be read."])
        }
        var server = obj["server"] as? [String: Any] ?? [:]
        server["port"] = port
        obj["server"] = server
        let backup = OMLX.settingsURL.appendingPathExtension("bak-llm-switcher-port")
        try? FileManager.default.removeItem(at: backup)
        try FileManager.default.copyItem(at: OMLX.settingsURL, to: backup)
        let out = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: OMLX.settingsURL, options: .atomic)
    }

    /// oMLX's port as its settings file says (what it will use on its next start).
    static func omlxConfiguredPort() -> Int? {
        guard let data = try? Data(contentsOf: OMLX.settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let server = obj["server"] as? [String: Any] else { return nil }
        return server["port"] as? Int
    }
}
