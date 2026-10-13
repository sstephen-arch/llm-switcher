import AppKit
import SwiftUI

// MARK: - Engines tab: ports for every server, and the Splash engine

struct EnginesSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Form {
            PortsSection()
            MemoryGuardSection()
            SplashSection(server: state.splash)
            ForEach(EngineKind.external, id: \.self) { k in
                if let e = state.externals[k] { ExternalEngineSection(engine: e) }
            }
        }
        .formStyle(.grouped)
        .task {
            state.splash.rescan()
            await state.refreshPorts()
        }
    }
}

struct PortsSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Section {
            ForEach(Ports.Service.allCases) { s in PortRow(service: s) }
            Text("Each server needs its own port. oMLX and Splash both default to 8000, so Splash runs on 8100 here. Changing oMLX's port restarts oMLX; scripts that call oMLX on its old port directly need the new one.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            HStack {
                Text("Ports")
                Spacer()
                Button("Check again") { Task { await state.refreshPorts() } }.buttonStyle(.link).font(.caption)
            }
        }
    }
}

struct MemoryGuardSection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Section("Memory") {
            Picker("Memory guard", selection: Binding(get: { state.config.memoryGuard },
                                                      set: { state.config.memoryGuard = $0; state.save() })) {
                ForEach(MemoryGuard.Mode.allCases) { Text($0.label).tag($0) }
            }
            Text("Engines don't see each other's memory. Before a model loads, LLM Switcher checks it fits beside the models other engines have loaded. If it doesn't, it unloads them (never one that's busy), or refuses with a message saying what to unload.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PortRow: View {
    @EnvironmentObject var state: AppState
    let service: Ports.Service
    @State private var text = ""
    @State private var error: String?
    @State private var saving = false
    @State private var confirmSplashMove = false

    var body: some View {
        let port = Ports.port(service, state.config)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(service.label)
                Spacer()
                ownerBadge(port)
                TextField("port", text: $text)
                    .textFieldStyle(.roundedBorder).frame(width: 70).multilineTextAlignment(.trailing)
                    .disabled(service == .gateway || saving)
                    .onSubmit {
                        // Splash can only move by restarting; say so before cutting anyone off.
                        if service == .splash && state.splash.phase != .stopped && Int(text) != Ports.port(service, state.config) {
                            confirmSplashMove = true
                        } else { apply() }
                    }
                if saving { ProgressView().controlSize(.small) }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if service == .gateway {
                Text("Fixed: Claude Desktop's profile, claude-omlx and the review hook use 11436.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Move Splash to port \(text)?", isPresented: $confirmSplashMove) {
            Button("Restart Splash on \(text)") { apply() }
            Button("Cancel", role: .cancel) { text = String(Ports.port(service, state.config)) }
        } message: { Text("Splash restarts on the new port. Anything using it now is cut off and the model loads again.") }
        .onAppear { text = String(port) }
        .onChange(of: port) { text = String($0) }
    }

    @ViewBuilder private func ownerBadge(_ port: Int) -> some View {
        if let o = state.portOwners[service] {
            Badge(text: expected(o) ? "listening" : "used by \(o.command)", color: expected(o) ? .green : .orange)
        } else {
            Badge(text: "free")
        }
    }

    /// The process on the port is the service that should be there.
    private func expected(_ o: Ports.Listener) -> Bool {
        switch service {
        case .gateway, .sharing: return o.pid == getpid()
        case .omlx, .splash, .ollama, .lmstudio, .llamacpp: return o.command == service.engine?.label
        }
    }

    private func apply() {
        guard let p = Int(text.trimmingCharacters(in: .whitespaces)) else {
            error = "Not a number."; text = String(Ports.port(service, state.config)); return
        }
        saving = true
        Task {
            error = await state.setPort(service, p)
            if error != nil { text = String(Ports.port(service, state.config)) }
            saving = false
        }
    }
}

struct SplashSection: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var server: SplashServer
    @State private var customModel = ""
    @State private var confirmRestart = false

    private static let contexts = [0, 32768, 65536, 131072, 262144]
    private static let efforts = ["", "none", "low", "medium", "high", "xhigh", "max"]
    private static let idles = ["off", "10m", "30m", "1h", "4h"]
    private static let cacheSizes = [0, 5, 10, 20, 50]

    var body: some View {
        let c = state.config.splash
        let set: (SplashConfig) -> Void = { state.setSplash($0) }
        Section {
            if !server.installed {
                Text("Splash isn't installed. Install it in Terminal, then come back here:").foregroundStyle(.secondary)
                Text("brew install incoai/tap/splash").font(.callout.monospaced()).textSelection(.enabled)
                Button("Check again") { server.rescan() }
            } else {
                status
                modelPicker(c, set)
                settings(c, set)
                logView
            }
        } header: {
            HStack {
                Text("Splash")
                if !server.version.isEmpty { Text(server.version).foregroundStyle(.secondary) }
                Spacer()
                Link("About Splash", destination: URL(string: "https://github.com/incoai/splash")!).font(.caption)
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                Text(server.phase.label).lineLimit(2).font(.callout)
                Spacer()
                switch server.phase {
                case .stopped, .failed:
                    Button("Start") { state.startSplash() }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.config.splash.model.isEmpty)
                case .starting, .ready:
                    if pendingChanges { Button("Restart to apply") { confirmRestart = true } }
                    Button("Stop") { state.stopSplash() }
                }
            }
            if server.isUp {
                HStack {
                    Text("Serving as").foregroundStyle(.secondary)
                    Text(server.servedModel).font(.callout.monospaced()).textSelection(.enabled)
                    Spacer()
                    Link("Open Splash chat", destination: URL(string: state.config.splash.upstream)!).font(.caption)
                }
                Text("Pick it for a Claude slot in the menu, share it, or tune it under Models. Every app reaches it through LLM Switcher.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Restart Splash?", isPresented: $confirmRestart) {
            Button("Restart") { state.startSplash() }
        } message: { Text("Anything using the Splash model now is cut off, and the model loads again (about a minute).") }
    }

    private var dotColor: Color {
        switch server.phase {
        case .ready: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .secondary
        }
    }

    private var pendingChanges: Bool { server.differs(from: state.config.splash) }

    @ViewBuilder private func modelPicker(_ c: SplashConfig, _ set: @escaping (SplashConfig) -> Void) -> some View {
        Picker("Model", selection: Binding(get: { c.model }, set: { var q = c; q.model = $0; set(q) })) {
            Text("Choose…").tag("")
            ForEach(server.cached) { m in
                Text("\(m.repo)  (\(ByteCountFormatter.string(fromByteCount: m.size, countStyle: .file))\(m.supported ? "" : ", may not be supported"))").tag(m.repo)
            }
            if !c.model.isEmpty && !server.cached.contains(where: { $0.repo == c.model }) {
                Text("\(c.model) (downloads on first start)").tag(c.model)
            }
        }
        HStack {
            TextField("Or a Hugging Face id, e.g. unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M", text: $customModel)
                .onSubmit { useCustom(c, set) }
            Button("Use") { useCustom(c, set) }.disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        Text("Splash 1.3 runs the \(Splash.families.joined(separator: " and ")) families, with a DFlash2 speed-up draft it picks itself. Models already in the Hugging Face cache start offline; others download on first start.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func useCustom(_ c: SplashConfig, _ set: (SplashConfig) -> Void) {
        let id = customModel.trimmingCharacters(in: .whitespaces)
        guard id.contains("/"), !id.contains(" ") else { return }
        var q = c; q.model = id; set(q)
        customModel = ""
    }

    @ViewBuilder private func settings(_ c: SplashConfig, _ set: @escaping (SplashConfig) -> Void) -> some View {
        Picker("Context limit", selection: Binding(get: { c.maxContext }, set: { var q = c; q.maxContext = $0; set(q) })) {
            Text("Automatic (model's window if memory allows)").tag(0)
            ForEach(Self.contexts.dropFirst(), id: \.self) { Text("\($0 / 1024)k").tag($0) }
            if !Self.contexts.contains(c.maxContext) { Text("\(c.maxContext / 1024)k").tag(c.maxContext) }
        }
        Picker("Default thinking", selection: Binding(get: { c.reasoningEffort }, set: { var q = c; q.reasoningEffort = $0; set(q) })) {
            ForEach(Self.efforts, id: \.self) { Text($0.isEmpty ? "Model template's default" : $0).tag($0) }
        }
        Text("Used when an app doesn't ask for a level. Qwen3.8's template defaults to xhigh, which thinks for a very long time.")
            .font(.caption).foregroundStyle(.secondary)
        Picker("KV cache", selection: Binding(get: { c.kvFormat }, set: { var q = c; q.kvFormat = $0; set(q) })) {
            Text("int8 (less memory)").tag("int8"); Text("bf16 (more memory)").tag("bf16")
        }
        Picker("Unload weights when idle (keeps running)", selection: Binding(get: { c.idleRelease }, set: { var q = c; q.idleRelease = $0; set(q) })) {
            ForEach(Self.idles, id: \.self) { Text($0 == "off" ? "Never (keep loaded)" : "After \($0)").tag($0) }
        }
        Stepper(value: Binding(get: { c.maxMemoryGB }, set: { var q = c; q.maxMemoryGB = max(0, $0); set(q) }), in: 0...512, step: 4) {
            Text("Memory budget: \(c.maxMemoryGB == 0 ? "automatic" : "\(c.maxMemoryGB) GB")")
        }
        Picker("SSD prompt cache", selection: Binding(get: { c.cacheDiskGB }, set: { var q = c; q.cacheDiskGB = $0; set(q) })) {
            ForEach(Self.cacheSizes, id: \.self) { Text($0 == 0 ? "Off" : "\($0) GB").tag($0) }
        }
        if c.cacheDiskGB > 0 {
            Toggle("Keep the SSD cache across restarts", isOn: Binding(get: { c.persistentCache }, set: { var q = c; q.persistentCache = $0; set(q) }))
        }
        Picker("Stop when unused", selection: Binding(get: { c.idleStopMinutes }, set: { var q = c; q.idleStopMinutes = $0; set(q) })) {
            Text("Never").tag(0)
            ForEach([10, 30, 60], id: \.self) { Text("After \($0) min").tag($0) }
        }
        Text("Only while Claude isn't using Splash: once nothing (shared computers, terminals) has asked it anything for this long, Splash stops and frees its memory. Start Claude (Splash) starts it again.")
            .font(.caption).foregroundStyle(.secondary)
        Toggle("Text only (skip loading vision)", isOn: Binding(get: { c.languageOnly }, set: { var q = c; q.languageOnly = $0; set(q) }))
        Toggle("Start Splash when LLM Switcher opens", isOn: Binding(get: { c.autoStart }, set: { var q = c; q.autoStart = $0; set(q) }))
        Text("Splash and oMLX share this Mac's memory, and oMLX doesn't count Splash's model. Unload large oMLX models before starting a large Splash model. Sampling (temperature, top-p …) is set per model under Models, since Splash has no per-model settings of its own.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private var logView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Log").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button("Open full log") { NSWorkspace.shared.open(SplashServer.logURL) }.buttonStyle(.link).font(.caption)
            }
            ScrollView {
                Text(server.log.suffix(14).joined(separator: "\n"))
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            .frame(height: 120)
        }
    }
}


/// Ollama, LM Studio or llama.cpp: switch it on, start/stop it, and its few settings.
struct ExternalEngineSection: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var engine: ExternalEngine

    private static let contexts = [0, 8192, 32768, 65536, 131072]
    private static let sleeps = [0, 10, 30, 60]

    var body: some View {
        let k = engine.kind
        let s = state.config.engine(k)
        let set: (EngineSettings) -> Void = { state.setEngineSettings(k, $0) }
        Section {
            if !engine.installed {
                Text("Not installed. To use it:").foregroundStyle(.secondary)
                Text(ExternalEngines.installHint(k)).font(.callout.monospaced()).textSelection(.enabled)
            } else {
                Toggle("Use \(k.label)", isOn: Binding(get: { s.enabled }, set: { state.setEngineEnabled(k, $0) }))
                HStack {
                    Circle().fill(engine.isUp ? Color.green : (engine.phase == .starting ? .yellow : .secondary)).frame(width: 8, height: 8)
                    Text(engine.label).font(.callout).lineLimit(2)
                    Spacer()
                    if engine.isUp {
                        if !engine.external { Button("Stop") { state.stopEngine(k) } }
                    } else {
                        Button("Start") { state.startEngine(k) }.disabled(engine.phase == .starting)
                    }
                    Button("Log") { NSWorkspace.shared.open(engine.logURL) }
                }
                switch k {
                case .ollama:
                    Picker("Context window", selection: Binding(get: { s.contextLength }, set: { var q = s; q.contextLength = $0; set(q) })) {
                        ForEach(Self.contexts, id: \.self) { Text($0 == 0 ? "Ollama's default" : "\($0 / 1024)k").tag($0) }
                    }
                    Text("Claude needs a big window; Ollama's own default is small. Applies when LLM Switcher starts Ollama (not the Ollama app).")
                        .font(.caption).foregroundStyle(.secondary)
                case .llamacpp:
                    PathField(label: "Models folder (GGUF)", path: s.modelsDir, placeholder: "its Hugging Face cache") { var q = s; q.modelsDir = $0; set(q) }
                    PathField(label: "Presets file (.ini)", path: s.presetFile, placeholder: "none") { var q = s; q.presetFile = $0; set(q) }
                    Picker("Free memory when idle", selection: Binding(get: { s.sleepIdleMinutes }, set: { var q = s; q.sleepIdleMinutes = $0; set(q) })) {
                        ForEach(Self.sleeps, id: \.self) { Text($0 == 0 ? "Never" : "After \($0) min").tag($0) }
                    }
                    Text("llama.cpp runs in multi-model mode: each model loads on its first request. Settings apply the next time it starts.")
                        .font(.caption).foregroundStyle(.secondary)
                case .lmstudio:
                    Text("Uses LM Studio's server through its lms tool. Turn on \"Just-in-time model loading\" in LM Studio so models load on request.")
                        .font(.caption).foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            }
        } header: {
            Text(k.label)
        }
    }
}

/// A file or folder path with a Choose… button.
struct PathField: View {
    let label: String
    let path: String
    let placeholder: String
    let commit: (String) -> Void

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(path.isEmpty ? placeholder : (path as NSString).abbreviatingWithTildeInPath)
                .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = label.contains("folder")
                panel.canChooseFiles = !label.contains("folder")
                if panel.runModal() == .OK, let url = panel.url { commit(url.path) }
            }
            if !path.isEmpty { Button("Clear") { commit("") } }
        }
    }
}
