import AppKit
import Foundation

/// Hugging Face search, downloads into oMLX's models folder, speed tests, removal (to the Trash),
/// and asking oMLX to rescan its folder.
enum HuggingFace {
    struct Result: Identifiable, Hashable {
        let id: String          // org/repo
        let downloads: Int
        let likes: Int
        let updated: String
    }

    /// MLX models matching `query`, most downloaded first.
    static func search(_ query: String) async -> [Result] {
        var c = URLComponents(string: "https://huggingface.co/api/models")!
        c.queryItems = [.init(name: "search", value: query), .init(name: "filter", value: "mlx"),
                        .init(name: "sort", value: "downloads"), .init(name: "limit", value: "25")]
        guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return list.compactMap {
            guard let id = $0["id"] as? String else { return nil }
            return Result(id: id, downloads: $0["downloads"] as? Int ?? 0, likes: $0["likes"] as? Int ?? 0,
                          updated: String(($0["lastModified"] as? String ?? "").prefix(10)))
        }
    }

    struct RepoFile { let path: String; let size: Int64 }

    /// Files worth downloading (weights, config, tokenizer, templates), skipping images and git files.
    static func files(_ repo: String) async throws -> [RepoFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true")!
        let (data, resp) = try await URLSession.shared.data(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NSError(domain: "HF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't list \(repo)"])
        }
        let skip = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".md"]
        return list.compactMap {
            guard ($0["type"] as? String) == "file", let p = $0["path"] as? String else { return nil }
            if p.hasPrefix(".git") || p.hasPrefix("assets/") || skip.contains(where: { p.lowercased().hasSuffix($0) }) { return nil }
            let size = ($0["lfs"] as? [String: Any])?["size"] as? Int64 ?? ($0["size"] as? Int64 ?? Int64($0["size"] as? Int ?? 0))
            return RepoFile(path: p, size: size)
        }
    }
}

/// What a repo is before downloading it: size, whether this Mac can hold it, and whether this
/// oMLX build can run it.
struct ModelCheck: Equatable {
    enum Fit: Equatable { case fits, tight, needsLimitRaised, tooBig }

    var size: Int64 = 0
    var architecture = ""
    var supported = true
    var helper = false              // an MTP / assistant drafter, not a chat model
    var hasMTP = false
    var quant = ""                  // "4-bit", "oQ6e", "bf16" …
    var problems: [String] = []     // reasons it may not run in oMLX
    var fit: Fit = .fits

    var runsInOMLX: Bool { supported && problems.isEmpty }

    static func classify(size: Int64, ceiling: Int64, ram: Int64) -> Fit {
        if ceiling > 0 && Double(size) <= 0.8 * Double(ceiling) { return .fits }
        if ceiling > 0 && size <= ceiling { return .tight }
        if size <= ram - 12 * 1_073_741_824 { return .needsLimitRaised }
        return .tooBig
    }

    static func describe(_ fit: Fit) -> String {
        switch fit {
        case .fits: return "Fits"
        case .tight: return "Fits, little room for long chats"
        case .needsLimitRaised: return "Needs the GPU memory limit raised"
        case .tooBig: return "Too big for this Mac"
        }
    }

    /// The command that raises macOS's GPU memory limit (leaves ~10 GB for macOS). Resets on restart.
    static func raiseLimitCommand(ram: Int64) -> String {
        "sudo sysctl iogpu.wired_limit_mb=\(max(0, Int(ram / 1_048_576) - 10_240))"
    }
}

extension HuggingFace {
    private static var archCache: Set<String>?

    /// Scans ~49,000 files inside oMLX.app once per launch, off the main thread.
    @MainActor
    static func architectures() async -> Set<String> {
        if let a = archCache { return a }
        let a = await Task.detached(priority: .utility) { OMLXAdmin.supportedArchitectures() }.value
        archCache = a
        return a
    }

    /// Size, architecture, MTP and format checks for a repo, from its file list and config.json.
    @MainActor
    static func check(_ repo: String, ceiling: Int64) async -> ModelCheck? {
        guard let files = try? await files(repo) else { return nil }
        var c = ModelCheck()
        c.size = files.reduce(0) { $0 + $1.size }
        let names = files.map { $0.path.lowercased() }
        var cfg: [String: Any] = [:]
        if let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/config.json"),
           let (data, _) = try? await URLSession.shared.data(from: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { cfg = obj }
        let text = cfg["text_config"] as? [String: Any] ?? [:]
        c.architecture = cfg["model_type"] as? String ?? ""
        c.helper = c.architecture.hasSuffix("_mtp") || c.architecture.hasSuffix("_assistant")
        let archs = await architectures()
        c.supported = c.architecture.isEmpty || archs.isEmpty || archs.contains(c.architecture)
        if !c.supported { c.problems.append("oMLX \(OMLXUpdater.installedVersion()) has no support for the \(c.architecture) architecture") }
        func int(_ k: String) -> Int { (cfg[k] as? Int) ?? (text[k] as? Int) ?? 0 }
        c.hasMTP = int("num_nextn_predict_layers") > 0 || int("mtp_num_hidden_layers") > 0 || int("mtp_num_layers") > 0
            || repo.lowercased().contains("mtp") || names.contains { $0.contains("mtp") && $0.hasSuffix(".safetensors") }
        let q = (cfg["quantization"] ?? cfg["quantization_config"]) as? [String: Any]
        let lower = repo.lowercased()
        if let r = lower.range(of: #"oq\d(\.\d)?e?"#, options: .regularExpression) {
            c.quant = String(lower[r]).replacingOccurrences(of: "oq", with: "oQ")
        } else if let bits = q?["bits"] as? Int {
            c.quant = "\(bits)-bit"
        } else if q == nil && names.contains(where: { $0.hasSuffix(".safetensors") }) {
            c.quant = "full precision"
        }
        if names.contains(where: { $0.hasSuffix(".gguf") }) && !names.contains(where: { $0.hasSuffix(".safetensors") }) {
            c.problems.append("GGUF files: oMLX runs MLX (safetensors) models")
        } else if !names.contains(where: { $0.hasSuffix(".safetensors") }) {
            c.problems.append("No safetensors weights: a custom format oMLX can't load")
        }
        if names.contains("model.inf") { c.problems.append("Made for another app's runtime (model.inf)") }
        if names.contains(where: { $0.hasSuffix(".py") && !$0.contains("/") }) {
            c.problems.append("Ships its own Python loader, which oMLX won't run")
        }
        if names.contains(where: { $0.hasSuffix("slotpack.json") || $0.hasPrefix("objects/") }) {
            c.problems.append("A compressed download package, not loadable weights")
        }
        c.fit = ModelCheck.classify(size: c.size, ceiling: ceiling, ram: Int64(ProcessInfo.processInfo.physicalMemory))
        return c
    }
}

/// Downloads one repo into ~/.omlx/models/<org>/<repo>, file by file, with progress.
@MainActor
final class ModelDownload: NSObject, ObservableObject, Identifiable, URLSessionDownloadDelegate {
    let repo: String
    let upstream: String
    var id: String { repo }
    @Published var received: Int64 = 0
    @Published var total: Int64 = 0
    @Published var state: String = "Starting…"
    @Published var finished = false
    @Published var failed = false
    private var doneBefore: Int64 = 0
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var continuation: CheckedContinuation<URL, Error>?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    init(repo: String, upstream: String) { self.repo = repo; self.upstream = upstream }

    var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }

    func run(onDone: @escaping () -> Void) {
        Task {
            do {
                let files = try await HuggingFace.files(repo)
                total = files.reduce(0) { $0 + $1.size }
                let dest = OMLX.modelsDir.appendingPathComponent(repo, isDirectory: true)
                try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
                for (i, f) in files.enumerated() {
                    if cancelled { throw CancellationError() }
                    // Repo paths must stay inside the model folder.
                    let parts = f.path.split(separator: "/")
                    guard !f.path.hasPrefix("/"), !parts.contains(where: { $0 == ".." || $0 == "." }) else {
                        throw NSError(domain: "HF", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsafe file path in repo: \(f.path)"])
                    }
                    let target = dest.appendingPathComponent(f.path)
                    if let size = try? FileManager.default.attributesOfItem(atPath: target.path)[.size] as? Int64, size == f.size, f.size > 0 {
                        doneBefore += f.size; received = doneBefore; continue      // already have it (resume)
                    }
                    state = "File \(i + 1) of \(files.count): \(f.path)"
                    let encoded = parts.map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? String($0) }.joined(separator: "/")
                    guard let url = URL(string: "https://huggingface.co/\(repo)/resolve/main/\(encoded)") else {
                        throw NSError(domain: "HF", code: 3, userInfo: [NSLocalizedDescriptionKey: "Bad file name in repo: \(f.path)"])
                    }
                    let tmp = try await download(url)
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try? FileManager.default.removeItem(at: target)       // a stale partial copy of a file we're replacing
                    try FileManager.default.moveItem(at: tmp, to: target)
                    doneBefore += f.size; received = doneBefore
                }
                state = "Loading into oMLX…"
                await OMLXAdmin.safeReload(upstream: upstream) { s in if let s { self.state = s } }
                // Turn on the model's built-in speed-up (MTP) when it has one: oMLX leaves it off.
                let id = (repo as NSString).lastPathComponent
                if let m = await OMLXAdmin.models(upstream: upstream).first(where: { $0.id == id }), m.mtpCompatible, !m.mtpOn {
                    await OMLXAdmin.updateSettings(id, ["mtp_enabled": true], upstream: upstream)
                    state = "Ready (MTP speed-up turned on)"
                } else {
                    state = "Ready"
                }
                finished = true
            } catch {
                failed = true
                state = cancelled ? "Cancelled" : "Failed: \(error.localizedDescription)"
            }
            onDone()
        }
    }

    func cancel() { cancelled = true; task?.cancel() }

    private func download(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            continuation = cont
            let t = session.downloadTask(with: url)
            task = t
            t.resume()
        }
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        MainActor.assumeIsolated { received = doneBefore + totalBytesWritten }
    }

    nonisolated func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temp file vanishes when this returns: move it somewhere we own first.
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: keep)
            MainActor.assumeIsolated { continuation?.resume(returning: keep); continuation = nil }
        } catch {
            MainActor.assumeIsolated { continuation?.resume(throwing: error); continuation = nil }
        }
    }

    nonisolated func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        MainActor.assumeIsolated { continuation?.resume(throwing: error); continuation = nil }
    }
}

extension OMLX {
    /// The folder holding a model, if it lives in oMLX's models folder (org/repo or a top-level name).
    static func folder(for model: String) -> URL? {
        let fm = FileManager.default
        let matches = ((try? fm.contentsOfDirectory(atPath: modelsDir.path)) ?? []).compactMap { org -> URL? in
            let u = modelsDir.appendingPathComponent(org).appendingPathComponent(model)
            return fm.fileExists(atPath: u.appendingPathComponent("config.json").path) ? u : nil
        }
        if matches.count == 1 { return matches[0] }
        if matches.count > 1 { return nil }       // same name under two orgs: don't guess
        let top = modelsDir.appendingPathComponent(model)
        return fm.fileExists(atPath: top.path) ? top : nil
    }

    /// Size on disk, for display.
    static func sizeOnDisk(_ model: String) -> Int64 {
        guard let dir = folder(for: model),
              let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e { total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    /// Remove a model completely, everything recoverable from the Trash: unload it, clear its oMLX
    /// settings, trash its folder and its prompt-cache files, then rescan once oMLX is idle.
    @MainActor
    static func moveToTrash(_ model: String, upstream: String, status: @escaping @MainActor (String?) -> Void) async throws {
        guard let dir = folder(for: model) else {
            throw NSError(domain: "ClaudeLocal", code: 1, userInfo: [NSLocalizedDescriptionKey: "Couldn't find \(model)'s folder"])
        }
        status("Unloading \(model)…")
        if let info = await OMLXAdmin.models(upstream: upstream).first(where: { $0.id == model }), info.loaded || info.loading {
            guard await OMLXAdmin.unload(model, upstream: upstream) else {
                throw NSError(domain: "ClaudeLocal", code: 2, userInfo: [NSLocalizedDescriptionKey: "oMLX couldn't unload \(model), so nothing was removed. Try again when it's idle."])
            }
            for _ in 0..<60 {          // an unload queued behind a running request finishes later
                guard let m = await OMLXAdmin.models(upstream: upstream).first(where: { $0.id == model }), m.loaded else { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        await OMLXAdmin.resetSettings(model, upstream: upstream)
        status("Moving \(model) to the Trash…")
        try await NSWorkspace.shared.recycle([dir])
        status("Removing its cache files…")
        do { try await OMLXCache.trash(model: model) }
        catch { Log.write("cache cleanup for \(model) incomplete: \(error.localizedDescription)") }
        // oMLX's "reset settings" leaves an entry full of defaults behind; drop it before the rescan
        // re-reads the file.
        removeSettingsEntry(model)
        await OMLXAdmin.safeReload(upstream: upstream, status: status)
    }

    /// Deletes a model's entry from oMLX's model_settings.json, leaving every other model untouched.
    static func removeSettingsEntry(_ model: String) {
        guard let data = try? Data(contentsOf: modelSettingsURL),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var models = obj["models"] as? [String: Any], models.removeValue(forKey: model) != nil else { return }
        obj["models"] = models
        if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: modelSettingsURL, options: .atomic)
        }
    }
}
