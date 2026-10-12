import Foundation

/// Finds a model's recommended sampling settings and thinking options from the people who made or
/// packaged it, so a model can be tuned before it's used (untuned models loop or overthink).
/// Sources, most trusted first: Unsloth's machine-readable `params` file for the base model, the
/// model's (and its base model's) `generation_config.json`, and its chat template for thinking
/// switches and levels. Nothing is applied here; the Models tab shows them next to the current
/// values and applies one only when asked.
enum BestConfig {
    struct Recommendation: Identifiable, Equatable {
        var id: String { source }
        let source: String
        let url: String
        var temperature: Double?
        var topP: Double?
        var topK: Int?
        var minP: Double?
        var presencePenalty: Double?
        var repetitionPenalty: Double?

        var isEmpty: Bool { [temperature, topP, minP, presencePenalty, repetitionPenalty].allSatisfy { $0 == nil } && topK == nil }

        var summary: String {
            var parts: [String] = []
            func add(_ name: String, _ v: Double?) { if let v { parts.append("\(name) \(Self.fmt(v))") } }
            add("temp", temperature); add("top-p", topP)
            if let k = topK { parts.append("top-k \(k)") }
            add("min-p", minP); add("presence", presencePenalty); add("repetition", repetitionPenalty)
            return parts.joined(separator: " · ")
        }

        static func fmt(_ v: Double) -> String { v == v.rounded() ? String(format: "%.1f", v) : String(format: "%g", v) }
    }

    struct Template: Equatable {
        /// The template has an enable_thinking switch (so "thinking off" works).
        var thinkingSwitch = false
        /// reasoning_effort levels it understands, e.g. ["low", "medium", "high", "xhigh"].
        var effortLevels: [String] = []
        var defaultEffort: String?
    }

    struct Result: Equatable {
        var recommendations: [Recommendation] = []
        var template: Template?
        var baseModel: String?
        var note: String?
    }

    static let levels = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    /// Where the model's files are: a local folder (oMLX, Splash's cache) and/or its Hugging Face repo.
    static func locate(_ model: String, engine: EngineKind, _ cfg: AppConfig) -> (dir: URL?, repo: String?) {
        let fm = FileManager.default
        switch engine {
        case .omlx:
            for org in (try? fm.contentsOfDirectory(atPath: OMLX.modelsDir.path)) ?? [] {
                let dir = OMLX.modelsDir.appendingPathComponent(org).appendingPathComponent(model)
                if fm.fileExists(atPath: dir.appendingPathComponent("config.json").path) { return (dir, "\(org)/\(model)") }
            }
            return (nil, nil)
        case .splash:
            let repo = cfg.splash.model.split(separator: ":").first.map(String.init) ?? cfg.splash.model
            let snaps = Splash.hubDir.appendingPathComponent("models--" + repo.replacingOccurrences(of: "/", with: "--"))
                .appendingPathComponent("snapshots")
            let dir = ((try? fm.contentsOfDirectory(at: snaps, includingPropertiesForKeys: nil)) ?? []).first
            return (dir, repo.isEmpty ? nil : repo)
        case .llamacpp:
            // Router ids from the Hugging Face cache look like "org/Repo-GGUF:Q4_K_M".
            let name = Endpoint(engine: .llamacpp, upstream: "", key: "").upstreamName(model)
            let repo = name.split(separator: ":").first.map(String.init) ?? name
            return (nil, repo.contains("/") ? repo : nil)
        default:
            return (nil, nil)
        }
    }

    static func lookup(_ model: String, engine: EngineKind, _ cfg: AppConfig) async -> Result {
        if engine == .ollama || engine == .lmstudio {
            return Result(note: "\(engine.label) applies its own library settings for each model, so nothing needs pulling here. Use the fields below only to override them.")
        }
        let (dir, repo) = locate(model, engine: engine, cfg)
        guard dir != nil || repo != nil else { return Result(note: "Couldn't find this model's files or Hugging Face page.") }
        var result = Result()

        // The model's own generation_config.json (local copy first).
        if let gc = await json("generation_config.json", dir: dir, repo: repo),
           let r = recommendation(from: gc, source: "This model's generation_config.json", url: hfURL(repo, "generation_config.json")), !r.isEmpty {
            result.recommendations.append(r)
        }

        // Its base model: generation_config.json, and Unsloth's tuned params for it.
        let base = await baseModel(dir: dir, repo: repo)
        result.baseModel = base
        if let base, base != repo {
            if let gc = await json("generation_config.json", dir: nil, repo: base),
               let r = recommendation(from: gc, source: "Base model (\(base)) generation_config.json", url: hfURL(base, "generation_config.json")), !r.isEmpty,
               !result.recommendations.contains(where: { $0.summary == r.summary }) {      // same advice twice says nothing new
                result.recommendations.append(r)
            }
        }
        for candidate in unslothRepos(base: base, repo: repo) {
            if let p = await json("params", dir: nil, repo: candidate),
               let r = recommendation(from: p, source: "Unsloth's tuned settings (\(candidate))", url: hfURL(candidate, "params")), !r.isEmpty {
                result.recommendations.insert(r, at: 0)      // most trusted: tuned by people who test them
                break
            }
        }

        result.template = await template(dir: dir, repo: repo)
        if result.recommendations.isEmpty {
            result.note = "No published settings found for this model or its base model."
        }
        return result
    }

    // MARK: sources

    static func recommendation(from obj: [String: Any], source: String, url: String) -> Recommendation? {
        func num(_ keys: String...) -> Double? {
            for k in keys { if let v = obj[k] as? Double { return v }; if let v = obj[k] as? Int { return Double(v) } }
            return nil
        }
        var r = Recommendation(source: source, url: url)
        r.temperature = num("temperature", "temp")
        r.topP = num("top_p")
        r.topK = num("top_k").map { Int($0) }
        r.minP = num("min_p")
        r.presencePenalty = num("presence_penalty")
        r.repetitionPenalty = num("repetition_penalty", "repeat_penalty")
        // A plain "do_sample: false" config only says "greedy"; don't present it as a recommendation.
        if obj["do_sample"] as? Bool == false && r.temperature == nil { return nil }
        return r
    }

    /// Unsloth publishes GGUF builds as unsloth/<BaseName>-GGUF with a `params` file.
    static func unslothRepos(base: String?, repo: String?) -> [String] {
        var repos: [String] = []
        for id in [base, repo].compactMap({ $0 }) {
            let name = cleanName(String(id.split(separator: "/").last ?? ""))
            let r = "unsloth/\(name)-GGUF"
            if !name.isEmpty && !repos.contains(r) { repos.append(r) }
        }
        return repos
    }

    /// "Qwen3.8-27B-8bit" -> "Qwen3.8-27B": drops quantisation and packaging suffixes.
    static func cleanName(_ name: String) -> String {
        let junk = ["-mlx", "-gguf", "-mtp", "-8bit", "-6bit", "-5bit", "-4bit", "-3bit", "-bf16", "-fp16", "-dwq",
                    "-mxfp4", "-q8", "-q6", "-q4", "-instruct-2507"]
        var n = name
        var changed = true
        while changed {
            changed = false
            let lower = n.lowercased()
            if let r = lower.range(of: #"-o?q\d[a-z0-9_]*$"#, options: .regularExpression) {      // -oQ4e, -Q4_K_M
                n = String(n[..<n.index(n.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.lowerBound))])
                changed = true; continue
            }
            for j in junk where lower.hasSuffix(j) {
                n = String(n.dropLast(j.count)); changed = true; break
            }
        }
        return n
    }

    static func baseModel(dir: URL?, repo: String?) async -> String? {
        if let dir, let text = try? String(contentsOf: dir.appendingPathComponent("README.md"), encoding: .utf8),
           let b = parseBaseModel(text) { return b }
        if let repo, let url = URL(string: "https://huggingface.co/api/models/\(repo)"),
           let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10)),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let card = obj["cardData"] as? [String: Any] {
            if let b = card["base_model"] as? String { return b }
            if let b = (card["base_model"] as? [String])?.first { return b }
        }
        return nil
    }

    /// `base_model:` from a model card's front matter (a single value or the first list item).
    static func parseBaseModel(_ readme: String) -> String? {
        guard readme.hasPrefix("---") else { return nil }
        let lines = readme.split(separator: "\n", omittingEmptySubsequences: false).prefix(80).map(String.init)
        for (i, line) in lines.enumerated() where line.hasPrefix("base_model:") {
            let v = line.dropFirst("base_model:".count).trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { return v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            if i + 1 < lines.count {
                let next = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if next.hasPrefix("- ") { return String(next.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
            }
        }
        return nil
    }

    static func template(dir: URL?, repo: String?) async -> Template? {
        var text = ""
        if let dir {
            text = (try? String(contentsOf: dir.appendingPathComponent("chat_template.jinja"), encoding: .utf8)) ?? ""
            if text.isEmpty, let tc = jsonFile(dir.appendingPathComponent("tokenizer_config.json")) { text = tc["chat_template"] as? String ?? "" }
        }
        if text.isEmpty, let repo {
            text = await fetchText(hfURL(repo, "chat_template.jinja")) ?? ""
            if text.isEmpty, let tc = await json("tokenizer_config.json", dir: nil, repo: repo) { text = tc["chat_template"] as? String ?? "" }
        }
        return text.isEmpty ? nil : parseTemplate(text)
    }

    static func parseTemplate(_ t: String) -> Template {
        var out = Template()
        out.thinkingSwitch = t.contains("enable_thinking")
        if t.contains("reasoning_effort") {
            out.effortLevels = levels.filter { t.contains("'\($0)'") || t.contains("\"\($0)\"") }
            let patterns = [#"reasoning_effort[^%}]*?default\(\s*['"](\w+)['"]"#, #"set\s+reasoning_effort\s*=\s*['"](\w+)['"]"#]
            for p in patterns {
                if let r = t.range(of: p, options: .regularExpression) {
                    let m = String(t[r])
                    if let q = m.range(of: #"['"](\w+)['"]$"#, options: .regularExpression) {
                        out.defaultEffort = m[q].trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                        break
                    }
                }
            }
        }
        return out
    }

    // MARK: fetching

    static func hfURL(_ repo: String?, _ file: String) -> String {
        "https://huggingface.co/\(repo ?? "")/resolve/main/\(file)"
    }

    private static func json(_ file: String, dir: URL?, repo: String?) async -> [String: Any]? {
        if let dir, let obj = jsonFile(dir.appendingPathComponent(file)) { return obj }
        guard let repo, let text = await fetchText(hfURL(repo, file)) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private static func jsonFile(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func fetchText(_ s: String) async -> String? {
        guard let url = URL(string: s),
              let (data, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 10)),
              (resp as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
