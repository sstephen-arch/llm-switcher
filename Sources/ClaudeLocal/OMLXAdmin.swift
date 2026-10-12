import Foundation

/// oMLX's admin API (the same one its web dashboard uses): per-model settings, load/unload,
/// and serving status. Logs in with oMLX's key for a session cookie; the key is never stored.
enum OMLXAdmin {
    /// One model as oMLX's dashboard sees it. Only the fields LLM Switcher shows are read.
    struct Model: Identifiable, Equatable {
        let id: String
        let path: String
        let engineType: String          // llm / vlm / embedding …
        let configType: String          // e.g. qwen3_5_moe
        let loaded: Bool
        let loading: Bool
        let sizeOnDisk: Int64           // oMLX's estimate of memory needed
        let contextLength: Int
        let mtpCompatible: Bool
        let mtpReason: String
        let pinned: Bool
        let isHelper: Bool
        let pleForcedToSSD: Bool
        let thinkingModes: [String]
        let settings: [String: AnyHashable]

        var mtpOn: Bool { (settings["mtp_enabled"] as? Bool) == true || (settings["vlm_mtp_enabled"] as? Bool) == true }
        var contextWindow: Int? { settings["max_context_window"] as? Int }
        var ttl: Int? { settings["ttl_seconds"] as? Int }
        var temperature: Double? { (settings["temperature"] as? NSNumber)?.doubleValue }
        var topP: Double? { (settings["top_p"] as? NSNumber)?.doubleValue }
        var topK: Int? { settings["top_k"] as? Int }
        var minP: Double? { (settings["min_p"] as? NSNumber)?.doubleValue }
        var presencePenalty: Double? { (settings["presence_penalty"] as? NSNumber)?.doubleValue }
        var repetitionPenalty: Double? { (settings["repetition_penalty"] as? NSNumber)?.doubleValue }
        var thinkingOn: Bool? { settings["enable_thinking"] as? Bool }

        init?(_ d: [String: Any]) {
            guard let id = d["id"] as? String else { return nil }
            self.id = id
            path = d["model_path"] as? String ?? ""
            engineType = d["engine_type"] as? String ?? (d["model_type"] as? String ?? "")
            configType = d["config_model_type"] as? String ?? ""
            loaded = d["loaded"] as? Bool ?? false
            loading = d["is_loading"] as? Bool ?? false
            sizeOnDisk = (d["estimated_size"] as? NSNumber)?.int64Value ?? 0
            contextLength = d["model_context_length"] as? Int ?? 0
            mtpCompatible = d["mtp_compatible"] as? Bool ?? false
            mtpReason = d["mtp_compatibility_reason"] as? String ?? ""
            pinned = d["pinned"] as? Bool ?? false
            isHelper = d["is_helper"] as? Bool ?? false
            pleForcedToSSD = (d["qwen4_ple_ssd_offload_forced"] as? Bool ?? false) || (d["deepseek_v41_engram_ssd_offload_forced"] as? Bool ?? false)
            thinkingModes = d["thinking_modes"] as? [String] ?? []
            var s: [String: AnyHashable] = [:]
            for (k, v) in d["settings"] as? [String: Any] ?? [:] {
                if let h = v as? AnyHashable, !(v is NSNull) { s[k] = h }
            }
            settings = s
        }
    }

    private static func session(_ upstream: String) async -> URLSession? {
        guard let login = URL(string: upstream + "/admin/api/login") else { return nil }
        let s = URLSession(configuration: .ephemeral)
        var req = URLRequest(url: login, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["api_key": OMLX.apiKey()])
        guard let (_, r) = try? await s.data(for: req), (r as? HTTPURLResponse)?.statusCode == 200 else {
            s.invalidateAndCancel(); return nil
        }
        return s
    }

    private static func call(_ upstream: String, _ method: String, _ path: String, body: Any? = nil,
                             timeout: TimeInterval = 30) async -> (Int, Any?) {
        guard let s = await session(upstream), let url = URL(string: upstream + "/admin" + path) else { return (0, nil) }
        defer { s.finishTasksAndInvalidate() }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, r) = try? await s.data(for: req) else { return (0, nil) }
        var obj = try? JSONSerialization.jsonObject(with: data)
        if var d = obj as? [String: Any] { d.removeValue(forKey: "api_key"); obj = d }   // never keep oMLX's key
        return ((r as? HTTPURLResponse)?.statusCode ?? 0, obj)
    }

    static func models(upstream: String) async -> [Model] {
        let (code, obj) = await call(upstream, "GET", "/api/models")
        guard code == 200, let list = (obj as? [String: Any])?["models"] as? [[String: Any]] else { return [] }
        return list.compactMap(Model.init).sorted { $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending }
    }

    /// Changes only the keys given; NSNull clears a setting back to oMLX's default.
    @discardableResult
    static func updateSettings(_ id: String, _ changes: [String: Any], upstream: String) async -> String? {
        let (code, obj) = await call(upstream, "PUT", "/api/models/\(escape(id))/settings", body: changes)
        if code == 200 { return nil }
        return ((obj as? [String: Any])?["detail"] as? String) ?? "oMLX refused the change (\(code))"
    }

    static func resetSettings(_ id: String, upstream: String) async {
        _ = await call(upstream, "POST", "/api/models/\(escape(id))/settings/reset")
    }

    @discardableResult
    static func load(_ id: String, upstream: String) async -> Bool {
        await call(upstream, "POST", "/api/models/\(escape(id))/load", timeout: 600).0 / 100 == 2
    }

    @discardableResult
    static func unload(_ id: String, upstream: String) async -> Bool {
        await call(upstream, "POST", "/api/models/\(escape(id))/unload", timeout: 120).0 / 100 == 2
    }

    /// Requests running or queued in oMLX right now (nil when oMLX can't be asked).
    static func busyRequests(upstream: String) async -> Int? {
        guard let s = await OMLX.servingStats(upstream: upstream) else { return nil }
        return s.activeRequests + s.waitingRequests
    }

    /// True when oMLX has nothing running. If the stats can't be read (oMLX busy or slow to
    /// answer), that only counts as idle when oMLX's health check fails too.
    static func looksIdle(upstream: String) async -> Bool {
        if let busy = await busyRequests(upstream: upstream) { return busy == 0 }
        return !(await OMLX.isRunning(upstream: upstream))
    }

    /// Re-scan oMLX's models folder, but only once nothing is running: a reload unloads every model
    /// and silently drops requests in progress (the caller then waits forever).
    /// Waits up to 15 minutes for oMLX to have nothing running. False if it stayed busy.
    static func waitUntilIdle(upstream: String, doing what: String, status: @escaping @MainActor (String?) -> Void) async -> Bool {
        for _ in 0..<450 {
            let busy = await busyRequests(upstream: upstream) ?? 0
            if busy == 0 { return true }
            await status("Waiting for \(busy) request\(busy == 1 ? "" : "s") to finish before \(what)…")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
    }

    @discardableResult
    static func safeReload(upstream: String, status: @escaping @MainActor (String?) -> Void) async -> Bool {
        guard await waitUntilIdle(upstream: upstream, doing: "reloading oMLX", status: status) else {
            await status("oMLX stayed busy for 15 minutes, so it wasn't reloaded. Use Reload in oMLX's dashboard when it's free.")
            return false
        }
        await status("Reloading oMLX…")
        _ = await call(upstream, "POST", "/api/reload", timeout: 180)
        await status(nil)
        return true
    }

    private static func escape(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }

    // MARK: what oMLX can run

    /// Architectures this oMLX build can load: the model folders bundled inside oMLX.app
    /// (mlx-lm, mlx-vlm and oMLX's own compatibility patches).
    static func supportedArchitectures() -> Set<String> {
        let res = OMLX.appURL.appendingPathComponent("Contents/Resources")
        let fm = FileManager.default
        var out = Set<String>()
        var dirs: [URL] = []
        if let e = fm.enumerator(at: res, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let u as URL in e where u.lastPathComponent == "models" {
                let parent = u.deletingLastPathComponent().lastPathComponent
                if parent == "mlx_lm" || parent == "mlx_vlm" { dirs.append(u); e.skipDescendants() }
            }
        }
        for d in dirs {
            for name in (try? fm.contentsOfDirectory(atPath: d.path)) ?? [] {
                if name.hasPrefix("_") || name.hasPrefix(".") { continue }
                out.insert(name.hasSuffix(".py") ? String(name.dropLast(3)) : name)
            }
        }
        return out
    }

    /// oMLX warnings that mention a model, newest first (from oMLX's own log). Lines carrying the key
    /// are skipped.
    static func warnings(for id: String, limit: Int = 3) -> [String] {
        let log = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".omlx/logs/server.log")
        guard let h = try? FileHandle(forReadingFrom: log) else { return [] }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 4_000_000 ? size - 4_000_000 : 0)
        let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
        var seen = Set<String>(), out: [String] = []
        for line in text.split(separator: "\n").reversed() where line.contains(" - WARNING - ") && line.contains(id) {
            if line.lowercased().contains("api_key") { continue }
            let msg = line.components(separatedBy: " - WARNING - ").last?.replacingOccurrences(of: "[-] - ", with: "") ?? String(line)
            let short = String(msg.prefix(260))
            if seen.insert(short).inserted { out.append(short) }
            if out.count == limit { break }
        }
        return out
    }
}
