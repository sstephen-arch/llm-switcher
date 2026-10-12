import Foundation

/// Talks to a Splash server (github.com/incoai/splash) and finds what it can run. Splash takes
/// Hugging Face ids only and keeps its weights in the Hugging Face cache, not in oMLX's folder.
enum Splash {
    static let binaryCandidates = ["/opt/homebrew/bin/splash", "/usr/local/bin/splash"]
    static var binary: String? { binaryCandidates.first { FileManager.default.isExecutableFile(atPath: $0) } }

    static let hubDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)

    /// The model families Splash 1.3 serves (each has a DFlash2 draft); others are refused at start.
    static let families = ["Qwen3.8-27B", "Qwen3.6-35B-A3B"]

    static func version() -> String {
        guard let bin = binary else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return "" }
        p.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "Splash ", with: "")
    }

    static func isRunning(port: Int) async -> Bool {
        guard port > 0, let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        guard let (_, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 2)),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return false }
        return code == 200
    }

    static func isReady(port: Int) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/ready"),
              let (_, resp) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 2)) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// The model names this Splash serves (empty when it's down, still loading, or not ours).
    static func models(_ cfg: SplashConfig) async -> [String] {
        // Not set up: don't ask (or send our key to) whatever else may listen on that port.
        guard !cfg.model.isEmpty else { return [] }
        let ep = Endpoint(engine: .splash, upstream: cfg.upstream, key: cfg.key)
        guard let req = ep.request("/v1/models", timeout: 2),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { return [] }
        let ids = list.compactMap { $0["id"] as? String }
        // Started by LLM Switcher: only the "splash/…" alias, so one model shows once.
        let aliases = ids.filter { $0.hasPrefix("splash/") }
        return aliases.isEmpty ? ids : aliases
    }

    /// Splash's own status (needs the key). Its process id lets us stop a server we didn't spawn
    /// this session (for example one left running after LLM Switcher was force-quit).
    static func status(_ cfg: SplashConfig) async -> [String: Any]? {
        let ep = Endpoint(engine: .splash, upstream: cfg.upstream, key: cfg.key)
        guard let req = ep.request("/status", timeout: 3),
              let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Requests Splash has taken so far, and how many are still running (nil when it can't say).
    static func activity(_ cfg: SplashConfig) async -> (submitted: Int, running: Int)? {
        guard let s = await status(cfg), let r = s["requests"] as? [String: Any],
              let submitted = r["submitted"] as? Int else { return nil }
        let done = ["completed", "cancelled", "failed"].reduce(0) { $0 + (r[$1] as? Int ?? 0) }
        return (submitted, max(0, submitted - done))
    }

    struct CachedModel: Identifiable, Hashable {
        var id: String { repo }
        let repo: String
        let size: Int64
        var supported: Bool { Splash.families.contains { repo.localizedCaseInsensitiveContains($0) } }
    }

    /// Models already in the Hugging Face cache (weights present, drafts left out). Splash can
    /// start these with --offline, without contacting the Hub.
    static func cachedModels() -> [CachedModel] {
        let fm = FileManager.default
        var out: [CachedModel] = []
        for dir in (try? fm.contentsOfDirectory(atPath: hubDir.path)) ?? [] where dir.hasPrefix("models--") {
            let parts = dir.dropFirst("models--".count).components(separatedBy: "--")
            guard parts.count >= 2 else { continue }
            let repo = parts[0] + "/" + parts.dropFirst().joined(separator: "--")
            if repo.hasSuffix("-DFlash2") || repo.localizedCaseInsensitiveContains("dflash") { continue }
            let size = folderSize(hubDir.appendingPathComponent(dir).appendingPathComponent("blobs"))
            if size > 500_000_000 { out.append(CachedModel(repo: repo, size: size)) }
        }
        return out.sorted { $0.repo < $1.repo }
    }

    static func isCached(_ model: String) -> Bool {
        let repo = model.split(separator: ":").first.map(String.init) ?? model
        return cachedModels().contains { $0.repo == repo }
    }

    private static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// `splash serve` arguments for these settings. The key goes in the environment, not here,
    /// so it never shows in `ps`.
    static func serveArguments(_ c: SplashConfig, offline: Bool) -> [String] {
        var a = ["serve", "--model", c.model, "--port", String(c.port), "--host", "127.0.0.1",
                 "--served-model-name", SplashConfig.servedName(c.model), "--announce-served-name",
                 "--idle-release", c.idleRelease.isEmpty ? "off" : c.idleRelease,
                 "--kv-format", c.kvFormat]
        if offline { a.append("--offline") }
        if c.maxContext > 0 { a += ["--max-context", String(c.maxContext)] }
        if !c.reasoningEffort.isEmpty { a += ["--default-reasoning-effort", c.reasoningEffort] }
        if c.maxMemoryGB > 0 { a += ["--max-memory", "\(c.maxMemoryGB)G"] }
        if c.cacheDiskGB > 0 {
            a += ["--max-cache-disk", "\(c.cacheDiskGB)G"]
            if c.persistentCache { a.append("--persistent-cache") }
        }
        if c.languageOnly { a.append("--language-only") }
        return a
    }
}

/// Starts, watches and stops the Splash server. One model at a time: Splash serves one per
/// process, and switching models restarts it.
@MainActor
final class SplashServer: ObservableObject {
    enum Phase: Equatable {
        case stopped, starting(String), ready, failed(String)

        var isFailed: Bool { if case .failed = self { return true } else { return false } }

        var label: String {
            switch self {
            case .stopped: return "Stopped"
            case .starting(let s): return s
            case .ready: return "Ready"
            case .failed(let s): return s
            }
        }
    }

    @Published private(set) var phase: Phase = .stopped
    @Published private(set) var log: [String] = []
    @Published private(set) var servedModel = ""
    @Published private(set) var installed = Splash.binary != nil
    @Published private(set) var version = ""
    @Published var cached: [Splash.CachedModel] = []
    /// The settings the running server was started with (nil when stopped), to spot unapplied changes.
    @Published private(set) var runningConfig: SplashConfig?

    private var process: Process?
    private var logHandle: FileHandle?
    private var startTask: Task<Void, Never>?
    /// True from Start until the server is ready or gives up (refresh leaves the phase alone then).
    private var launching = false
    static let logURL = Log.url.deletingLastPathComponent().appendingPathComponent("splash.log")

    var isUp: Bool { phase == .ready }

    /// Running with settings other than `c` (auto-start doesn't count): a restart would apply them.
    func differs(from c: SplashConfig) -> Bool {
        guard var running = runningConfig else { return false }
        var saved = c
        running.autoStart = false; saved.autoStart = false
        return running != saved
    }

    init() {
        Task.detached { [weak self] in
            let v = Splash.version(), models = Splash.cachedModels()
            await MainActor.run { self?.version = v; self?.cached = models }
        }
    }

    func rescan() {
        installed = Splash.binary != nil
        Task.detached { [weak self] in
            let models = Splash.cachedModels()
            await MainActor.run { self?.cached = models }
        }
    }

    /// Picks up a Splash already serving on our port with our key (e.g. after a crash of this app).
    func refresh(_ cfg: SplashConfig) async {
        if launching { return }
        let models = await Splash.models(cfg)
        if !models.isEmpty {
            servedModel = models[0]
            phase = .ready
        } else if phase == .ready, !(await Splash.isRunning(port: cfg.port)) {
            // A busy server can miss one model list; only a server that's gone counts as stopped.
            phase = .failed("Splash stopped unexpectedly. See the log below.")
            servedModel = ""
        }
    }

    func start(_ cfg: AppConfig) {
        let c = cfg.splash
        guard let bin = Splash.binary else { phase = .failed("Splash isn't installed (brew install incoai/tap/splash)."); return }
        guard !c.model.isEmpty else { phase = .failed("Choose a model for Splash first."); return }
        if let clash = Ports.clash(for: .splash, port: c.port, cfg) { phase = .failed(clash); return }
        startTask?.cancel()
        phase = .starting("Starting…")
        startTask = Task {
            launching = true
            defer { launching = false }
            await stopAndWait(cfg, keepPhase: true)
            guard !Task.isCancelled else { return }
            if let owner = await Ports.listener(c.port) {
                phase = .failed("Port \(c.port) is already used by \(owner.command) (pid \(owner.pid)). Pick another port.")
                return
            }
            let model = c.model
            let offline = await Task.detached { Splash.isCached(model) }.value
            // Stop or another Start came in meanwhile: don't spawn a process nobody wants.
            guard !Task.isCancelled else { return }
            phase = .starting(offline ? "Loading \(c.model)…" : "Downloading \(c.model) (first start)…")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = Splash.serveArguments(c, offline: offline)
            var env = ProcessInfo.processInfo.environment
            env["SPLASH_API_KEY"] = c.key
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            openLog()
            appendLog("--- splash \(p.arguments!.joined(separator: " "))")
            pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
                let data = h.availableData
                guard !data.isEmpty else { h.readabilityHandler = nil; return }
                let text = String(decoding: data, as: UTF8.self)
                Task { @MainActor in self?.appendLog(text) }
            }
            p.terminationHandler = { [weak self] proc in
                Task { @MainActor in
                    guard let self, self.process === proc else { return }
                    self.process = nil
                    self.servedModel = ""
                    self.runningConfig = nil
                    if case .stopped = self.phase { return }
                    let last = self.log.suffix(3).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                    self.phase = .failed("Splash exited (code \(proc.terminationStatus)). \(last)")
                }
            }
            do { try p.run() } catch {
                phase = .failed("Couldn't start Splash: \(error.localizedDescription)")
                return
            }
            process = p
            runningConfig = c
            Log.write("splash started pid \(p.processIdentifier) on port \(c.port) model \(c.model)")
            // A first start downloads tens of GB; give it up to two hours.
            for _ in 0..<7200 {
                if Task.isCancelled || process !== p || !p.isRunning { return }
                if await Splash.isReady(port: c.port) {
                    servedModel = await Splash.models(c).first ?? SplashConfig.servedName(c.model)
                    phase = .ready
                    Log.write("splash ready: \(servedModel)")
                    return
                }
                if let line = log.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    phase = .starting(String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)))
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    func stop(_ cfg: AppConfig) {
        startTask?.cancel()
        startTask = Task { await stopAndWait(cfg) }
    }

    /// Ctrl+C first (Splash finishes cleanly), then a hard stop if it hangs.
    private func stopAndWait(_ cfg: AppConfig, keepPhase: Bool = false) async {
        let wasActive = phase != .stopped
        if !keepPhase { phase = .stopped }
        servedModel = ""
        runningConfig = nil
        var pid: pid_t = 0
        if let p = process, p.isRunning { pid = p.processIdentifier }
        else if let s = await Splash.status(cfg.splash), let inst = s["instance"] as? [String: Any],
                let n = inst["pid"] as? Int, n > 0,
                let owner = await Ports.listener(cfg.splash.port), owner.pid == pid_t(n), owner.command == "Splash" {
            pid = owner.pid      // ours, left from an earlier run: it knows our key and really is Splash
        }
        process = nil
        guard pid > 0 else { return }
        if wasActive { Log.write("stopping splash pid \(pid)") }
        kill(pid, SIGINT)
        for _ in 0..<30 {
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        kill(pid, SIGKILL)
        for _ in 0..<20 {
            if kill(pid, 0) != 0 { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Called when LLM Switcher quits: Splash can't be reached without the gateway anyway.
    func stopNow() {
        guard let p = process, p.isRunning else { return }
        kill(p.processIdentifier, SIGINT)
    }

    private func openLog() {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: Self.logURL.path) { fm.createFile(atPath: Self.logURL.path, contents: nil) }
        logHandle = try? FileHandle(forWritingTo: Self.logURL)
        logHandle?.seekToEndOfFile()
    }

    private func appendLog(_ text: String) {
        logHandle?.write(Data(text.hasSuffix("\n") ? text.utf8 : (text + "\n").utf8))
        // Progress bars redraw with \r; keep the last state of each line.
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
            .map { $0.components(separatedBy: "\r").last(where: { !$0.isEmpty }) ?? "" }
        log = Array((log + lines).suffix(200))
    }
}
