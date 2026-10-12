import Foundation

/// Talks to the local oMLX server. oMLX requires its API key even on loopback; the key is read
/// from oMLX's own settings each time and is never stored or logged by LLM Switcher.
enum OMLX {
    static let settingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".omlx/settings.json")
    static let modelSettingsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".omlx/model_settings.json")
    static let modelsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".omlx/models", isDirectory: true)
    static let appURL = URL(fileURLWithPath: "/Applications/oMLX.app")

    static func apiKey() -> String {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = obj["auth"] as? [String: Any] else { return "" }
        return auth["api_key"] as? String ?? ""
    }

    /// Chat models installed in oMLX's models folder (whether or not oMLX is running). oMLX names a
    /// model after its folder; speed-up helpers are left out.
    static func installedModels() -> [String] {
        let fm = FileManager.default
        var names: [String] = []
        for org in (try? fm.contentsOfDirectory(atPath: modelsDir.path)) ?? [] {
            let orgURL = modelsDir.appendingPathComponent(org)
            for name in (try? fm.contentsOfDirectory(atPath: orgURL.path)) ?? []
            where fm.fileExists(atPath: orgURL.appendingPathComponent(name).appendingPathComponent("config.json").path) {
                names.append(name)
            }
        }
        let helpers = helperModelIDs()
        return names.filter { !helpers.contains($0) }.sorted()
    }

    /// Speculative-decoding add-ons (MTP / assistant drafters). They are not chat models.
    static func helperModelIDs() -> Set<String> {
        var ids = Set<String>()
        if let data = try? Data(contentsOf: modelSettingsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = obj["models"] as? [String: [String: Any]] {
            for settings in models.values {
                for key in ["vlm_mtp_draft_model", "dflash_draft_model", "specprefill_draft_model"] {
                    if let id = settings[key] as? String, !id.isEmpty { ids.insert(id) }
                }
            }
        }
        let fm = FileManager.default
        for org in (try? fm.contentsOfDirectory(atPath: modelsDir.path)) ?? [] {
            let orgURL = modelsDir.appendingPathComponent(org)
            for name in (try? fm.contentsOfDirectory(atPath: orgURL.path)) ?? [] {
                let cfg = orgURL.appendingPathComponent(name).appendingPathComponent("config.json")
                guard let data = try? Data(contentsOf: cfg),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = obj["model_type"] as? String else { continue }
                if type.hasSuffix("_mtp") || type.hasSuffix("_assistant") { ids.insert(name) }
            }
        }
        return ids
    }

    static func request(_ path: String, upstream: String, timeout: TimeInterval = 5) -> URLRequest? {
        guard let url = URL(string: upstream + path) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        let key = apiKey()
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return req
    }

    /// Chat models oMLX can serve now (empty when oMLX is down or has none).
    static func models(upstream: String) async -> [String] {
        guard let req = request("/v1/models", upstream: upstream),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return [] }
        let hidden = helperModelIDs()
        return list.compactMap { $0["id"] as? String }.filter { !hidden.contains($0) }.sorted()
    }

    static func isRunning(upstream: String) async -> Bool {
        guard let req = request("/health", upstream: upstream, timeout: 3),
              let (_, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return false }
        return code < 500
    }
}
