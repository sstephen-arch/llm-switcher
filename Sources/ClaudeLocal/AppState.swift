import AppKit
import Foundation
import Network
import ServiceManagement
import SwiftUI

/// Everything the menu and the settings window show, plus the actions behind their buttons.
@MainActor
final class AppState: ObservableObject {
    @Published var config = AppConfig.load()
    /// Every chat model the engines serve now (oMLX and Splash), and which engine serves each.
    @Published var models: [String] = []
    @Published var engineOf: [String: EngineKind] = [:]
    /// Every model each engine has, running or not: installed on disk (oMLX, Splash) or last
    /// reported by the engine (all of them). The slot pickers list these, so stopping an engine
    /// never empties them.
    @Published var installed: [EngineKind: [String]] = [:]
    /// What each engine last reported serving, kept across restarts (by EngineKind raw value).
    private var lastSeen: [String: [String]] = UserDefaults.standard.dictionary(forKey: "lastSeenModels") as? [String: [String]] ?? [:]
    /// The engine the menu shows and edits. Claude keeps using `config.engine` (the live one)
    /// until Start/Switch Claude makes this one live, so a flip of the switch never breaks Claude.
    @Published var viewEngine: EngineKind = .omlx
    /// Who is listening on each configured port right now (nil = nobody).
    @Published var portOwners: [Ports.Service: Ports.Listener] = [:]
    @Published var omlxRunning = false
    @Published var gatewayRunning = false
    @Published var mode: ClaudeProfile.Mode = .cloud
    @Published var busy: String?
    @Published var lastError: String?
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var shareRunning = false
    @Published var activity: [Gateway.Activity] = []
    @Published var addresses: [LANAddress] = []
    @Published var usage: [UsageRow] = []
    @Published var downloads: [ModelDownload] = []
    @Published var speed: [String: String] = [:]          // model -> last speed test result
    @Published var certFingerprint = ""
    @Published var system = SystemSample()
    @Published var serving: ServingStats?
    /// Last 30 samples (every 2 s) for the history graphs.
    @Published var cpuHistory: [[Double]] = []      // one array per core group
    @Published var gpuHistory: [Double] = []
    /// oMLX's view of each model (settings, loaded, MTP), from its admin API.
    @Published var adminModels: [OMLXAdmin.Model] = []
    @Published var cache: [OMLXCache.Entry] = []
    @Published var cacheScanning = false

    let updater = OMLXUpdater()
    let splash = SplashServer()
    /// Ollama, LM Studio and llama.cpp.
    let externals: [EngineKind: ExternalEngine] = Dictionary(uniqueKeysWithValues: EngineKind.external.map { ($0, ExternalEngine($0)) })
    let reviewLoop = ReviewLoop()
    let benchmark = Benchmark()

    let gateway = Gateway(kind: .local)
    let shareGateway = Gateway(kind: .shared)
    private var timer: Timer?
    private var statsTimer: Timer?
    private let sampler = SystemSampler()
    private var statsTick = 0

    init() {
        viewEngine = config.engine
        // One copy only: a second one would find the gateway's ports taken. Hand over and quit.
        let testing = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let me = ProcessInfo.processInfo.processIdentifier
        if !testing, let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != me }) {
            Log.write("another copy is already running (pid \(other.processIdentifier)); quitting this one")
            other.activate()
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return
        }
        // Gateways re-read the file per request: slot, key and preset changes apply instantly.
        gateway.config = { AppConfig.load() }
        shareGateway.config = { AppConfig.load() }
        let onActivity: (Gateway.Activity) -> Void = { [weak self] a in
            Task { @MainActor in
                guard let self else { return }
                self.activity.insert(a, at: 0)
                if self.activity.count > RequestLog.keep { self.activity.removeLast(self.activity.count - RequestLog.keep) }
                RequestLog.append(a)
            }
        }
        gateway.onActivity = onActivity
        shareGateway.onActivity = onActivity
        // A request for a stopped engine's model starts that engine and waits for it.
        let ensure: (EngineKind) async -> Bool = { [weak self] kind in
            guard let self else { return false }
            // Requests only start engines that are switched on; switching one on is the owner's
            // call (menu, Engines tab or lsw), never a shared computer's.
            if EngineKind.external.contains(kind) && !self.config.engine(kind).enabled { return false }
            return await self.ensureEngine(kind)
        }
        gateway.ensureEngine = ensure
        shareGateway.ensureEngine = ensure
        gateway.control = { [weak self] action, args in
            guard let self else { return (503, ["error": "quitting"]) }
            return await self.control(action, args)
        }
        activity = RequestLog.load()
        UsageStore.shared.onChange = { [weak self] in self?.usage = UsageStore.shared.snapshot() }
        usage = UsageStore.shared.snapshot()
        // The unit-test host runs beside the real app: it must not fight it for the gateway's ports.
        if !testing {
            unifySplashPicks()
            startGateway()
            if config.shareEnabled { startSharing() }
        }
        // Not under unit tests: the test host would replace the user's running Splash.
        if config.splash.autoStart && !config.splash.model.isEmpty && !testing { splash.start(config) }
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sampleStats() }
        }
        sampleStats()
        Task {
            await updater.check()
            await refreshAdmin()
        }
    }

    // MARK: system stats

    func sampleStats() {
        let s = sampler.sample()
        system = s
        if cpuHistory.count != s.coreGroups.count { cpuHistory = Array(repeating: [], count: s.coreGroups.count) }
        for (i, g) in s.coreGroups.enumerated() { cpuHistory[i] = Array((cpuHistory[i] + [g.usage]).suffix(30)) }
        gpuHistory = Array((gpuHistory + [s.gpu ?? 0]).suffix(30))
        statsTick += 1
        if statsTick % 3 == 1 {          // oMLX's serving stats every ~6 s
            Task { serving = await OMLX.servingStats(upstream: config.upstream) }
        }
    }

    // MARK: state

    func refresh() async {
        let cfg = config
        await splash.refresh(cfg.splash)
        for e in externals.values where cfg.engine(e.kind).enabled { await e.refresh(cfg) }
        followServedSplashModel()
        await stopSplashIfUnused()
        async let c = Engines.catalog(cfg)
        async let r = OMLX.isRunning(upstream: cfg.upstream)
        let catalog = await c
        models = catalog.keys.sorted()
        engineOf = catalog.mapValues(\.engine)
        await refreshInstalled()
        omlxRunning = await r
        gatewayRunning = gateway.isRunning
        if !gatewayRunning { startGateway() }
        shareRunning = shareGateway.isRunning
        if config.shareEnabled && !shareRunning { startSharing() }
        let now = LAN.lanAddresses()
        if now != addresses {
            addresses = now
            // A new address needs a certificate that covers it.
            if config.shareEnabled && config.tlsEnabled { startSharing() }
        }
        mode = ClaudeProfile.currentMode()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func save() { config.save() }

    func startGateway() {
        do { try gateway.start(port: config.port) }
        catch { lastError = "Gateway couldn't start on port \(config.port): \(error.localizedDescription)" }
    }

    func assign(_ slot: ClaudeSlot, to model: String) {
        // Splash runs one model: picking another downloaded one switches Splash (and its slots) to it.
        if viewEngine == .splash, !model.isEmpty, model != SplashConfig.servedName(config.splash.model),
           let repo = splash.cached.first(where: { SplashConfig.servedName($0.repo) == model })?.repo {
            chooseSplashModel(repo)
        }
        var picks = slotPicks(viewEngine)
        if viewEngine == .splash && !model.isEmpty {
            picks = SplashConfig.unifiedPicks(picks, model: model)
        }
        picks[slot.id] = model.isEmpty ? nil : model
        setPicks(picks, for: viewEngine)
        save()
    }

    /// Repairs Splash picks that name different models (older versions could leave them so): every
    /// Splash slot uses the model Splash is set to run.
    private func unifySplashPicks() {
        let served = SplashConfig.servedName(config.splash.model)
        let picks = slotPicks(.splash)
        let fixed = SplashConfig.unifiedPicks(picks, model: served)
        if fixed != picks {
            Log.write("Splash slots named different models; all now use \(served)")
            setPicks(fixed, for: .splash)
            save()
        }
    }

    /// An engine's Claude slot picks. The live engine's are `config.slots` (what the gateway uses).
    func slotPicks(_ e: EngineKind) -> [String: String] {
        e == config.engine ? config.slots : (config.engineSlots[e.rawValue] ?? defaultSlots(e))
    }

    private func setPicks(_ picks: [String: String], for e: EngineKind) {
        if e == config.engine { config.slots = picks } else { config.engineSlots[e.rawValue] = picks }
    }

    func setAutoMode(_ on: Bool) { config.autoMode = on; save() }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: network sharing

    func setSharing(_ on: Bool) {
        config.shareEnabled = on
        if on && config.clients.isEmpty { config.clients = [ShareClient(name: "My first computer")] }
        save()
        if on { startSharing() } else { shareGateway.stop(); shareRunning = false }
    }

    func startSharing() {
        do {
            var identity: sec_identity_t? = nil
            if config.tlsEnabled {
                identity = try TLSCert.identity()
                certFingerprint = TLSCert.fingerprint()
            }
            let name = config.bonjour ? "LLM Switcher on \(LAN.computerName())" : nil
            try shareGateway.start(port: config.sharePort, tlsIdentity: identity, bonjourName: name)
        } catch {
            lastError = "Sharing couldn't start on port \(config.sharePort): \(error.localizedDescription)"
        }
        addresses = LAN.lanAddresses()
    }

    func setTLS(_ on: Bool) {
        config.tlsEnabled = on; save()
        if config.shareEnabled { startSharing() }
    }

    func newCertificate() {
        do { _ = try TLSCert.identity(regenerate: true); certFingerprint = TLSCert.fingerprint() }
        catch { lastError = error.localizedDescription }
        if config.shareEnabled { startSharing() }
    }

    func setBonjour(_ on: Bool) {
        config.bonjour = on; save()
        if config.shareEnabled { startSharing() }
    }

    // Clients (one key per person or computer)

    func addClient(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        config.clients.append(ShareClient(name: trimmed.isEmpty ? "Computer \(config.clients.count + 1)" : trimmed))
        save()
    }

    func updateClient(_ c: ShareClient) {
        guard let i = config.clients.firstIndex(where: { $0.id == c.id }) else { return }
        config.clients[i] = c
        save()
    }

    func newKey(for c: ShareClient) {
        var copy = c; copy.key = AppConfig.newShareKey(); updateClient(copy)
    }

    func removeClient(_ c: ShareClient) {
        config.clients.removeAll { $0.id == c.id }
        save()
    }

    /// nil sharedModels means "share every model", including ones added later.
    func isShared(_ model: String) -> Bool { config.sharedModels?.contains(model) ?? true }

    func setShared(_ model: String, _ on: Bool) {
        var list = config.sharedModels ?? models
        if on { if !list.contains(model) { list.append(model) } } else { list.removeAll { $0 == model } }
        config.sharedModels = Set(list) == Set(models) ? nil : list.sorted()
        save()
    }

    var sharedModelList: [String] { models.filter { isShared($0) } }

    var scheme: String { config.tlsEnabled ? "https" : "http" }

    /// Best address to give people: the first home-network IPv4, else the .local name.
    var shareBaseURL: String {
        let host = addresses.first?.ip ?? LAN.localHostName()
        return "\(scheme)://\(host):\(config.sharePort)"
    }

    /// The engine shown in the menu has at least one Claude slot picked.
    var hasAssignments: Bool { slotPicks(viewEngine).values.contains { !$0.isEmpty } }

    // MARK: presets

    func preset(_ model: String) -> ModelPreset { config.preset(for: model) }

    func setPreset(_ model: String, _ p: ModelPreset) {
        config.presets[model] = p == ModelPreset() ? nil : p
        save()
    }

    // MARK: models (download, test, remove)

    func download(_ repo: String) {
        guard !downloads.contains(where: { $0.repo == repo && !$0.finished && !$0.failed }) else { return }
        let d = ModelDownload(repo: repo, upstream: config.upstream)
        downloads.insert(d, at: 0)
        d.run { [weak self] in Task { await self?.refresh(); await self?.refreshAdmin() } }
    }

    func testSpeed(_ model: String) {
        speed[model] = "Testing…"
        // Same test as the benchmark's writing speed, through the gateway (tuned settings, and a
        // stopped engine starts).
        let base = "http://127.0.0.1:\(config.port)"
        Task {
            let prompt = [["role": "user", "content": "Explain how a hash map works, in about 300 words."]]
            if let r = await Benchmark.stream(base, model, prompt, maxTokens: 400), let w = r.writeSpeed {
                speed[model] = String(format: "%.0f tokens/s · first word %.1fs", w, r.firstWord)
            } else {
                speed[model] = "Test failed (is \(Engines.kind(of: model).label) running?)"
            }
        }
    }

    /// oMLX's models only (its admin settings, load/unload and Trash apply to these).
    var omlxModels: [String] { Set(models.filter { engineOf[$0] == .omlx }).union(installed[.omlx] ?? []).sorted() }

    /// The models the slot pickers offer: only the chosen engine's. Splash serves one model, so
    /// that's the one chosen for it (listed even while Splash is stopped; Start Claude starts it).
    var pickerModels: [String] {
        var names = Set(models.filter { engineOf[$0] == viewEngine })
        names.formUnion(installed[viewEngine] ?? [])
        if viewEngine == .splash {
            // The chosen model, and the one still running until "Restart to apply".
            if !config.splash.model.isEmpty { names.insert(SplashConfig.servedName(config.splash.model)) }
            if splash.isUp, !splash.servedModel.isEmpty { names.insert(splash.servedModel) }
        }
        return names.sorted()
    }

    /// Updates `installed`: what each engine serves now becomes its remembered list; oMLX's folder
    /// and Splash's downloads are read from disk, so they show even before an engine first runs.
    func refreshInstalled(force: Bool = false) async {
        for k in EngineKind.allCases {
            let served = models.filter { engineOf[$0] == k }
            if !served.isEmpty { lastSeen[k.rawValue] = served }
        }
        UserDefaults.standard.set(lastSeen, forKey: "lastSeenModels")
        // Reading the disks launches llama.cpp's cache lister: about once a minute, or when the
        // menu or Settings opens (force), not on every 4-second refresh.
        if force || Date().timeIntervalSince(lastDiskScan) > 60 {
            lastDiskScan = Date()
            onDisk = await Task.detached { () -> [EngineKind: [String]] in
                var d: [EngineKind: [String]] = [
                    .omlx: OMLX.installedModels(),
                    .splash: Splash.cachedModels().filter(\.supported).map { SplashConfig.servedName($0.repo) }]
                for k in EngineKind.external { d[k] = ExternalEngines.downloadedModels(k).map { "\(k.prefix!)/\($0)" } }
                return d
            }.value
        }
        var out: [EngineKind: [String]] = [:]
        for k in EngineKind.allCases {
            var names = Set(models.filter { engineOf[$0] == k }).union(onDisk[k] ?? [])
            // oMLX and Splash: the disk is the truth, so a deleted model never lingers. The others
            // also keep what they last reported (LM Studio's folder isn't readable as model names).
            if k != .omlx && k != .splash { names.formUnion(lastSeen[k.rawValue] ?? []) }
            out[k] = names.sorted()
        }
        if installed != out { installed = out }
    }

    private var lastDiskScan = Date.distantPast
    private var onDisk: [EngineKind: [String]] = [:]

    /// Models known but not served right now (their engine is stopped): every engine's slot picks
    /// and the chosen Splash model. Asking for one starts its engine.
    var stoppedModels: [String] {
        var names = Set(config.slots.values)
        for picks in config.engineSlots.values { names.formUnion(picks.values) }
        if !config.splash.model.isEmpty { names.insert(SplashConfig.servedName(config.splash.model)) }
        return names.subtracting(models).filter { !$0.isEmpty }.sorted()
    }

    /// Engines to offer in the menu: oMLX always, the others when installed or switched on.
    var availableEngines: [EngineKind] {
        EngineKind.allCases.filter { k in
            switch k {
            case .omlx: return true
            case .splash: return splash.installed
            default: return config.engine(k).enabled || (externals[k]?.installed ?? false)
            }
        }
    }

    /// Whether an engine is up right now.
    func isRunning(_ k: EngineKind) -> Bool {
        switch k {
        case .omlx: return omlxRunning
        case .splash: return splash.isUp
        default: return externals[k]?.isUp ?? false
        }
    }

    /// Starts an engine if it isn't running and waits for it. Used by Start Claude, by requests
    /// for a stopped engine's model, and by the `lsw` command. False when it couldn't start.
    func ensureEngine(_ k: EngineKind) async -> Bool {
        switch k {
        case .omlx:
            if await OMLX.isRunning(upstream: config.upstream) { return true }
            openOMLX()
            for _ in 0..<45 {
                if await OMLX.isRunning(upstream: config.upstream) { omlxRunning = true; return true }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            return false
        case .splash:
            // Saved settings (e.g. a new model) that the running Splash doesn't have yet.
            // New settings, or (after an app restart) a running Splash serving another model.
            let wanted = SplashConfig.servedName(config.splash.model)
            if splash.differs(from: config.splash) || (splash.isUp && !splash.servedModel.isEmpty && splash.servedModel != wanted) {
                splash.start(config)
            }
            let ok = await ensureSplash()
            followServedSplashModel()
            return ok
        default:
            guard let e = externals[k] else { return false }
            if !config.engine(k).enabled { setEngineEnabled(k, true) }
            return await e.start(config)
        }
    }

    /// The `lsw` command's requests (loopback gateway only).
    func control(_ action: String, _ args: [String: Any]) async -> (Int, [String: Any]) {
        let engineArg = (args["engine"] as? String).flatMap { name in
            EngineKind.allCases.first { $0.rawValue == name.lowercased() || $0.label.lowercased() == name.lowercased() }
        }
        switch action {
        case "status":
            await refresh()
            let engines: [[String: Any]] = EngineKind.allCases.map { k in
                ["name": k.rawValue, "label": k.label, "running": isRunning(k),
                 "available": availableEngines.contains(k), "port": k == .omlx ? config.omlxPort : (k == .splash ? config.splash.port : config.engine(k).port),
                 "models": models.filter { engineOf[$0] == k },
                 "installed": Set(models.filter { engineOf[$0] == k }).union(installed[k] ?? []).sorted()]
            }
            return (200, ["engine": config.engine.rawValue, "shown": viewEngine.rawValue,
                          "claude": mode == .claudeLocal ? "local" : "cloud", "slots": config.slots,
                          "engines": engines, "gateway": config.port, "sharing": shareRunning ? config.sharePort : 0])
        case "ensure":
            // A slot id or model name; or just an engine.
            let k: EngineKind
            var target = ""
            if let name = args["model"] as? String, !name.isEmpty {
                target = config.slots[name] ?? name
                k = Engines.kind(of: target)
            } else if let e = engineArg { k = e } else { return (400, ["error": "give a model, slot or engine"]) }
            guard await ensureEngine(k) else { return (502, ["error": "\(k.label) didn't start"]) }
            await refresh()
            if !target.isEmpty && !models.contains(target) {
                return (404, ["error": "\(target) isn't served by \(k.label)", "engine": k.rawValue])
            }
            return (200, ["ok": true, "engine": k.rawValue, "model": target])
        case "use":
            guard let k = engineArg, availableEngines.contains(k) else { return (400, ["error": "unknown or unavailable engine"]) }
            setEngine(k)
            let note = mode == .claudeLocal && k != config.engine
                ? "Claude Desktop is still on \(config.engine.label); press Switch Claude in the menu." : ""
            return (200, ["engine": config.engine.rawValue, "shown": k.rawValue, "note": note])
        case "start":
            guard let k = engineArg else { return (400, ["error": "which engine?"]) }
            return await ensureEngine(k) ? (200, ["ok": true]) : (502, ["error": "\(k.label) didn't start"])
        case "stop":
            guard let k = engineArg, k != .omlx else { return (400, ["error": "oMLX is stopped from its own app"]) }
            stopEngine(k)
            return (200, ["ok": true])
        case "bench":
            guard let name = args["model"] as? String, !name.isEmpty else { return (400, ["error": "which model?"]) }
            var o = Benchmark.Options()
            if let c = args["coding"] as? String { o.coding = c }
            if let t = args["thinking"] as? String { o.thinking = t }
            if let s = args["speed"] as? Bool { o.speed = s }
            if let t = args["tools"] as? Bool { o.tools = t }
            let target = config.slots[name] ?? name
            guard let r = await benchmark.runAndWait(model: target, options: o, gateway: config.port) else {
                return (502, ["error": benchmark.running ? "a benchmark is already running" : "the benchmark didn't finish", "log": benchmark.steps])
            }
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            let obj = (try? JSONSerialization.jsonObject(with: enc.encode(r))) as? [String: Any] ?? [:]
            return (200, ["result": obj, "log": benchmark.steps])
        case "recommend":
            guard let name = args["model"] as? String, !name.isEmpty else { return (400, ["error": "which model?"]) }
            let target = config.slots[name] ?? name
            let r = await BestConfig.lookup(target, engine: Engines.kind(of: target), config)
            let recs: [[String: Any]] = r.recommendations.map { ["source": $0.source, "url": $0.url, "settings": $0.summary] }
            var out: [String: Any] = ["model": target, "recommendations": recs]
            if let n = r.note { out["note"] = n }
            if let b = r.baseModel { out["base_model"] = b }
            if let t = r.template {
                out["thinking_switch"] = t.thinkingSwitch
                out["thinking_levels"] = t.effortLevels
                if let d = t.defaultEffort { out["thinking_default"] = d }
            }
            return (200, out)
        default:
            return (404, ["error": "unknown action"])
        }
    }

    func clearRequests() {
        activity = []
        RequestLog.clear()
    }

    func setEngineEnabled(_ k: EngineKind, _ on: Bool) {
        var s = config.engine(k)
        s.enabled = on
        config.engines[k.rawValue] = s
        save()
        if !on, let e = externals[k], e.isUp, !e.external { Task { await e.stop(config) } }
    }

    func setEngineSettings(_ k: EngineKind, _ s: EngineSettings) {
        config.engines[k.rawValue] = s
        save()
    }

    func startEngine(_ k: EngineKind) { Task { if !(await ensureEngine(k)) { lastError = "\(k.label) didn't start." } } }

    func stopEngine(_ k: EngineKind) {
        switch k {
        case .omlx: return
        case .splash: stopSplash()
        default: if let e = externals[k] { Task { await e.stop(config) } }
        }
    }

    /// Shows the other engine in the menu. While Claude runs locally it keeps its current engine
    /// until Switch Claude; otherwise the choice is live at once (for the terminal launchers).
    func setEngine(_ e: EngineKind) {
        viewEngine = e
        if mode != .claudeLocal { makeLive(e) }
    }

    /// Makes `e` the engine the gateway serves Claude's slots from. Each engine keeps its picks.
    private func makeLive(_ e: EngineKind) {
        guard e != config.engine else { return }
        let picks = slotPicks(e)
        config.engineSlots[config.engine.rawValue] = config.slots
        config.engineSlots[e.rawValue] = nil
        config.engine = e
        config.slots = picks
        save()
    }

    /// First switch to an engine: Splash serves one model, so it goes on the Sonnet 5 slot only
    /// (five slots with one name would just repeat it in Claude's model menu). oMLX starts empty.
    private func defaultSlots(_ e: EngineKind) -> [String: String] {
        guard e == .splash, !config.splash.model.isEmpty else { return [:] }
        return ["claude-sonnet-5": SplashConfig.servedName(config.splash.model)]
    }

    // MARK: Splash

    func setSplash(_ c: SplashConfig) {
        // Slots move to the new model now, running or not. If Splash is still serving the old one,
        // the next request for the new model restarts it (Gateway.route), so a slot never waits on
        // a model Splash won't load.
        renameSplashModel(from: SplashConfig.servedName(config.splash.model), to: SplashConfig.servedName(c.model))
        config.splash = c
        save()
    }

    /// Points every slot (live and saved) that used Splash model `old` at `new`; "" clears them.
    private func renameSplashModel(from old: String, to new: String) {
        guard !old.isEmpty, old != new else { return }
        let swap: ([String: String]) -> [String: String] = { picks in
            picks.compactMapValues { $0 == old ? (new.isEmpty ? nil : new) : $0 }
        }
        config.slots = swap(config.slots)
        config.engineSlots = config.engineSlots.mapValues(swap)
    }

    /// Splash came up serving a different model than before: its slots follow it.
    private var lastServedSplash = ""
    private func followServedSplashModel() {
        let now = splash.servedModel
        guard splash.isUp, !now.isEmpty else { return }
        if !lastServedSplash.isEmpty && lastServedSplash != now {
            renameSplashModel(from: lastServedSplash, to: now)
            save()
        }
        lastServedSplash = now
    }

    func startSplash() { lastError = nil; splash.start(config) }

    /// Picks the model Splash serves; a running Splash restarts on it.
    func chooseSplashModel(_ model: String) {
        guard model != config.splash.model else { return }
        var c = config.splash
        c.model = model
        setSplash(c)
        // A running Splash keeps its model until "Restart to apply", as in Settings.
    }

    /// Splash is running with settings other than the saved ones.
    var splashNeedsRestart: Bool { splash.differs(from: config.splash) }
    func stopSplash() { splash.stop(config) }

    /// Waits for Splash to be ready, starting it first. False when it fails or takes too long.
    func ensureSplash() async -> Bool {
        if splash.isUp { return true }
        if case .starting = splash.phase {} else { splash.start(config) }
        for _ in 0..<7200 {          // a first start downloads tens of GB (same allowance as SplashServer)
            if splash.isUp { return true }
            if case .failed = splash.phase { return false }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        return false
    }

    // MARK: ports

    func refreshPorts() async {
        var owners: [Ports.Service: Ports.Listener] = [:]
        for s in Ports.Service.allCases {
            if let l = await Ports.listener(Ports.port(s, config)) { owners[s] = l }
        }
        portOwners = owners
    }

    /// Moves one service to a new port. Returns why it couldn't, or nil when done.
    func setPort(_ service: Ports.Service, _ port: Int) async -> String? {
        if Ports.port(service, config) == port { return nil }
        if let clash = Ports.clash(for: service, port: port, config) { return clash }
        if let owner = await Ports.listener(port) {
            return "Port \(port) is in use by \(owner.command) (pid \(owner.pid))."
        }
        switch service {
        case .gateway:
            return "The Claude gateway stays on 11436: Claude's profile, claude-omlx and the review hook all expect it."
        case .sharing:
            config.sharePort = port; save()
            if config.shareEnabled { startSharing() }
        case .splash:
            let wasUp = splash.phase != .stopped
            if wasUp { await stopSplashAndWait() }
            config.splash.port = port; save()
            if wasUp { splash.start(config) }
        case .ollama, .lmstudio, .llamacpp:
            let k = service.engine!
            let e = externals[k]!
            let wasOurs = e.isUp && !e.external
            if wasOurs { await e.stop(config) }
            var s = config.engine(k); s.port = port
            setEngineSettings(k, s)
            if wasOurs { _ = await e.start(config) }
        case .omlx:
            let old = config.upstream, oldPort = config.omlxPort
            do { try Ports.setOMLXPort(port) } catch { return error.localizedDescription }
            config.upstream = "http://127.0.0.1:\(port)"; save()
            if omlxRunning, !(await restartOMLX(runningAt: old)) {
                // oMLX is still on its old port: point everything back at it.
                try? Ports.setOMLXPort(oldPort)
                config.upstream = old; save()
                await refresh()
                return "oMLX didn't quit (was its quit dialog cancelled?), so its port wasn't changed."
            }
        }
        await refreshPorts()
        await refresh()
        return nil
    }

    private func stopSplashAndWait() async {
        splash.stop(config)
        for _ in 0..<40 {
            if !(await Splash.isRunning(port: config.splash.port)) { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Quits oMLX once nothing is running and opens it again (it reads its port at start).
    /// False when oMLX didn't quit; nothing is reopened then.
    func restartOMLX(runningAt current: String) async -> Bool {
        busy = "Waiting for oMLX to be idle…"
        _ = await OMLXAdmin.waitUntilIdle(upstream: current, doing: "restarting oMLX") { [weak self] s in self?.busy = s }
        busy = "Restarting oMLX (it may ask you to confirm quitting)…"
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: OMLXUpdater.bundleID) { app.terminate() }
        var quit = false
        for _ in 0..<60 {
            if NSRunningApplication.runningApplications(withBundleIdentifier: OMLXUpdater.bundleID).isEmpty { quit = true; break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard quit else { busy = nil; return false }
        openOMLX()
        for _ in 0..<45 {
            if await OMLX.isRunning(upstream: config.upstream) { break }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        busy = nil
        return true
    }

    func trashModel(_ model: String) {
        Task {
            do {
                try await OMLX.moveToTrash(model, upstream: config.upstream) { s in self.busy = s }
                for (slot, m) in config.slots where m == model { config.slots[slot] = nil }
                config.engineSlots = config.engineSlots.mapValues { $0.filter { $0.value != model } }
                config.presets[model] = nil
                save()
            } catch { lastError = error.localizedDescription }
            busy = nil
            await refresh()
            await refreshAdmin()
        }
    }

    // MARK: oMLX model settings, memory and cache

    func refreshAdmin() async {
        adminModels = await OMLXAdmin.models(upstream: config.upstream)
    }

    func adminModel(_ id: String) -> OMLXAdmin.Model? { adminModels.first { $0.id == id } }

    /// Changes oMLX's own settings for a model (MTP, context window, keep loaded …).
    func setOMLX(_ model: String, _ changes: [String: Any]) {
        Task {
            if let err = await OMLXAdmin.updateSettings(model, changes, upstream: config.upstream) { lastError = err }
            await refreshAdmin()
        }
    }

    func load(_ model: String) {
        Task {
            busy = "Loading \(model)…"
            if !(await OMLXAdmin.load(model, upstream: config.upstream)) { lastError = "oMLX couldn't load \(model)" }
            busy = nil
            await refreshAdmin()
        }
    }

    func unload(_ model: String) {
        Task {
            await OMLXAdmin.unload(model, upstream: config.upstream)
            await refreshAdmin()
        }
    }

    /// The memory oMLX may use for models (its own limit), else macOS's usual GPU share.
    var memoryCeiling: Int64 {
        if let m = serving?.modelMemoryMax, m > 0 { return m }
        return Int64(Double(ProcessInfo.processInfo.physicalMemory) * 0.75)
    }

    var ram: Int64 { Int64(ProcessInfo.processInfo.physicalMemory) }

    func scanCache() {
        guard !cacheScanning else { return }
        cacheScanning = true
        Task {
            cache = await OMLXCache.usage()
            cacheScanning = false
        }
    }

    func clearCache(_ model: String) {
        Task {
            do { try await OMLXCache.trash(model: model) } catch { lastError = error.localizedDescription }
            cache = await OMLXCache.usage()
        }
    }

    func upgradeOMLX(_ r: OMLXUpdater.Release) {
        Task {
            await updater.install(r, upstream: config.upstream)
            await refresh()
            await refreshAdmin()
        }
    }

    // MARK: Claude mode

    func startClaudeLocal() {
        Task {
            lastError = nil
            let target = viewEngine
            guard hasAssignments else {
                lastError = "Pick a \(target.label) model for at least one Claude slot first."
                return
            }
            // The chosen engine must be up before Claude is switched; if it isn't, Claude is left alone.
            busy = "Starting \(target.label)…"
            guard await ensureEngine(target) else {
                lastError = "\(target.label) didn't start, so Claude wasn't switched."
                busy = nil
                return
            }
            makeLive(target)
            // Leaving Splash frees its memory, unless other computers may be using it.
            if target != .splash && splash.phase != .stopped && !splashSharedOut { splash.stop(config) }
            busy = "Restarting Claude on \(target.label)…"
            let port = config.port, auto = config.autoMode
            do {
                try ClaudeProfile.applyFiles(port: port, autoMode: auto)
                try await ClaudeProfile.restartClaude { try ClaudeProfile.applyFiles(port: port, autoMode: auto) }
            } catch {
                lastError = error.localizedDescription
            }
            busy = nil
            await refresh()
        }
    }

    /// Splash's request count when last seen, and since when nothing new has come in.
    private var splashSeen = (submitted: -1, since: Date())

    /// Claude isn't on Splash and nobody (shared computers, terminals) has used it for a while:
    /// stop it so its model's memory comes back. Counted from Splash's own request counter.
    private func stopSplashIfUnused() async {
        let minutes = config.splash.idleStopMinutes
        guard minutes > 0, splash.isUp else { splashSeen = (-1, Date()); return }
        if mode == .claudeLocal && config.engine == .splash { splashSeen = (-1, Date()); return }
        guard let a = await Splash.activity(config.splash) else { return }
        if a.submitted != splashSeen.submitted || a.running > 0 {
            splashSeen = (a.submitted, Date())
        } else if Date().timeIntervalSince(splashSeen.since) >= Double(minutes * 60) {
            Log.write("splash unused for \(minutes) min and Claude isn't on it; stopping to free memory")
            splash.stop(config)
            splashSeen = (-1, Date())
        }
    }

    /// Network sharing is on and the Splash model is shared, so someone else may be using it.
    var splashSharedOut: Bool {
        shareRunning && !config.splash.model.isEmpty && isShared(SplashConfig.servedName(config.splash.model))
    }

    func backToCloud() {
        Task {
            lastError = nil
            if splash.phase != .stopped && !splashSharedOut { splash.stop(config) }
            busy = "Restarting Claude on the cloud…"
            do {
                try ClaudeProfile.restoreFiles()
                try await ClaudeProfile.restartClaude { try ClaudeProfile.restoreFiles() }
            } catch {
                lastError = error.localizedDescription
            }
            busy = nil
            await refresh()
        }
    }

    func openOMLX() {
        NSWorkspace.shared.openApplication(at: OMLX.appURL, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    func quit() {
        gateway.stop()
        shareGateway.stop()
        splash.stopNow()
        for e in externals.values { e.stopNow() }
        UsageStore.shared.flush()
        NSApp.terminate(nil)
    }
}
