import SwiftUI

@main
struct ClaudeLocalApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuPanel()
                .environmentObject(state)
        } label: {
            Image(systemName: state.mode == .claudeLocal ? "cpu.fill" : "cpu")
        }
        .menuBarExtraStyle(.window)

        // A normal window rather than SwiftUI's Settings scene: menu bar-only apps can't reliably
        // bring the Settings scene forward from the menu panel.
        Window("LLM Switcher", id: SettingsWindow.id) {
            SettingsView()
                .environmentObject(state)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsCommand()
            }
        }
    }
}

/// Opens the settings window on a given tab and brings it to the front.
enum SettingsWindow {
    static let id = "settings"
    static let tabKey = "settingsTab"

    @MainActor
    static func open(_ openWindow: OpenWindowAction, tab: String? = nil) {
        if let tab { UserDefaults.standard.set(tab, forKey: tabKey) }
        // A menu bar-only app has to act like a normal app for its window to come forward;
        // it goes back to menu bar-only when the window closes (see SettingsView.onDisappear).
        NSApp.setActivationPolicy(.regular)
        openWindow(id: id)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            for w in NSApp.windows where w.identifier?.rawValue.contains(id) == true || w.title == "LLM Switcher" {
                w.makeKeyAndOrderFront(nil)
                w.orderFrontRegardless()
            }
        }
    }
}

struct SettingsCommand: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Settings…") { SettingsWindow.open(openWindow) }.keyboardShortcut(",")
    }
}

// MARK: - Menu bar panel

struct MenuPanel: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("LLM Switcher").font(.headline)
                Spacer()
                Text(state.mode == .claudeLocal ? "Claude on \(state.config.engine.label)" : state.mode.label)
                    .font(.caption).foregroundStyle(.secondary)
            }
            let engines = state.availableEngines
            if engines.count > 1 {
                let picker = Picker("Engine", selection: Binding(get: { state.viewEngine }, set: { state.setEngine($0) })) {
                    ForEach(engines, id: \.self) { Text($0.label).tag($0) }
                }
                if engines.count <= 3 { picker.pickerStyle(.segmented).labelsHidden() }
                else { picker.pickerStyle(.menu) }
            }
            // The shown engine, plus any other that's running: one left running still holds memory.
            HStack(spacing: 14) {
                ForEach(engines.filter { $0 == state.viewEngine || state.isRunning($0) }, id: \.self) { k in
                    if k == .splash { SplashDot(server: state.splash) }
                    else { StatusDot(label: k.label, on: state.isRunning(k)) }
                }
                StatusDot(label: "Gateway", on: state.gatewayRunning)
            }
            if state.mode == .claudeLocal && state.viewEngine != state.config.engine {
                Text("Claude is using \(state.config.engine.label). Pick \(state.viewEngine.label) models below, then press Switch Claude.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            StatsStrip()

            if state.viewEngine == .splash {
                Divider()
                MenuSplashRow(server: state.splash)
            } else if let e = state.externals[state.viewEngine] {
                Divider()
                MenuEngineRow(engine: e)
            }

            Divider()
            SlotPickers()

            Divider()
            ShareRow()

            if let busy = state.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy).font(.caption) }
            }
            if let err = state.lastError {
                Text(err).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button(startLabel) { state.startClaudeLocal() }
                    .buttonStyle(.borderedProminent)
                    .disabled(state.busy != nil || !state.hasAssignments)
                Button("Back to Claude cloud") { state.backToCloud() }
                    .disabled(state.busy != nil || state.mode == .cloud)
            }
            Text("Both buttons quit and reopen Claude.").font(.caption2).foregroundStyle(.secondary)

            Divider()
            HStack {
                if state.viewEngine == .omlx { Button("Open oMLX") { state.openOMLX() } }
                Button("Settings…") { SettingsWindow.open(openWindow) }
                Spacer()
                Button("Quit") { state.quit() }
            }
        }
        .padding(14)
        .task { await state.refreshInstalled(force: true) }      // freshly installed models show at once
        .frame(width: 390)
    }

    /// Start when Claude is on the cloud, Switch when it's local on the other engine, else Restart.
    private var startLabel: String {
        let e = state.viewEngine.label
        guard state.mode == .claudeLocal else { return "Start Claude (\(e))" }
        return state.viewEngine == state.config.engine ? "Restart Claude (\(e))" : "Switch Claude to \(e)"
    }
}

struct SlotPickers: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Claude model slots").font(.subheadline.weight(.semibold))
            if state.pickerModels.isEmpty {
                Text(emptyText).font(.caption).foregroundStyle(.secondary)
            }
            if state.viewEngine == .splash && state.pickerModels.count > 1 {
                Text("Splash runs one model at a time: picking another downloaded model switches every Splash slot to it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Slots.all) { slot in
                HStack {
                    Text(slot.label).frame(width: 80, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { state.slotPicks(state.viewEngine)[slot.id] ?? "" },
                        set: { state.assign(slot, to: $0) }
                    )) {
                        Text("None").tag("")
                        ForEach(state.pickerModels, id: \.self) { Text($0).tag($0) }
                        if let cur = state.slotPicks(state.viewEngine)[slot.id], !cur.isEmpty, !state.pickerModels.contains(cur) {
                            Text("\(cur) (not available)").tag(cur)
                        }
                    }
                    .labelsHidden()
                }
            }
        }
    }

    private var emptyText: String {
        switch state.viewEngine {
        case .omlx: return state.omlxRunning ? "oMLX has no models yet. Add one in Settings → Models." : "oMLX isn't running. Press Open oMLX below, then pick its models here."
        case .splash: return "Choose a Splash model above."
        default:
            let k = state.viewEngine
            return state.isRunning(k) ? "\(k.label) has no models yet." : "\(k.label) isn't running. Press Start above to see its models."
        }
    }
}

/// Ollama / LM Studio / llama.cpp: state and Start/Stop.
struct MenuEngineRow: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var engine: ExternalEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            Circle().fill(engine.isUp ? Color.green : (engine.phase == .starting ? .yellow : .secondary)).frame(width: 7, height: 7)
            Text(engine.installed ? engine.label : "Not installed").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            if !engine.installed {
                Button("How to install…") { SettingsWindow.open(openWindow, tab: "engines") }.controlSize(.small)
            } else if engine.isUp {
                if !engine.external { Button("Stop") { state.stopEngine(engine.kind) }.controlSize(.small) }
            } else {
                Button("Start") { state.startEngine(engine.kind) }.controlSize(.small).disabled(engine.phase == .starting)
            }
        }
    }
}

/// Splash mode: its one model, its state, and Start/Stop.
struct MenuSplashRow: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var server: SplashServer
    @Environment(\.openWindow) private var openWindow
    @State private var confirmRestart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Splash model", selection: Binding(get: { state.config.splash.model }, set: { state.chooseSplashModel($0) })) {
                    Text("Choose…").tag("")
                    ForEach(server.cached) { m in Text(m.repo).tag(m.repo) }
                    if !state.config.splash.model.isEmpty && !server.cached.contains(where: { $0.repo == state.config.splash.model }) {
                        Text(state.config.splash.model).tag(state.config.splash.model)
                    }
                }
                switch server.phase {
                case .stopped, .failed:
                    Button("Start") { state.startSplash() }
                        .controlSize(.small)
                        .disabled(state.config.splash.model.isEmpty)
                case .starting, .ready:
                    Button("Stop") { state.stopSplash() }.controlSize(.small)
                }
            }
            if server.cached.isEmpty && state.config.splash.model.isEmpty {
                Button("Add a Splash model…") { SettingsWindow.open(openWindow, tab: "engines") }.controlSize(.small)
            }
            if state.splashNeedsRestart {
                HStack {
                    Text("Splash is still running the old settings.").font(.caption).foregroundStyle(.orange)
                    Button("Restart to apply") { confirmRestart = true }.controlSize(.small)
                }
            } else if !state.config.splash.model.isEmpty && !server.isUp {
                Text(server.phase == .stopped ? "Stopped. Start Claude starts it." : server.phase.label)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .confirmationDialog("Restart Splash?", isPresented: $confirmRestart) {
            Button("Restart") { state.startSplash() }
        } message: { Text("Anything using Splash now is cut off, and the model loads again.") }
    }
}

struct SplashDot: View {
    @ObservedObject var server: SplashServer
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("Splash").font(.caption)
        }
        .help(server.phase.label)
    }

    private var color: Color {
        switch server.phase {
        case .ready: return .green
        case .starting: return .yellow
        case .failed: return .red
        case .stopped: return .secondary
        }
    }
}

struct StatusDot: View {
    let label: String
    let on: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(on ? Color.green : Color.red).frame(width: 7, height: 7)
            Text(label).font(.caption)
        }
    }
}

// MARK: - Settings window

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @AppStorage(SettingsWindow.tabKey) private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Form {
                Section("Claude") {
                    Toggle("Auto mode with local models", isOn: Binding(
                        get: { state.config.autoMode }, set: { state.setAutoMode($0) }))
                    Text("Off is recommended: in auto mode Claude checks each action with the local model, which is often busy and times out.")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("Current mode", value: state.mode.label)
                }
                Section("General") {
                    Toggle("Open LLM Switcher at login", isOn: Binding(
                        get: { state.launchAtLogin }, set: { state.setLaunchAtLogin($0) }))
                    LabeledContent("Gateway", value: "127.0.0.1:\(state.config.port)")
                    LabeledContent("oMLX", value: state.config.upstream)
                    LabeledContent("Splash", value: state.config.splash.upstream)
                }
                OMLXUpdateSection(updater: state.updater)
            }
            .formStyle(.grouped)
            .tag("general")
            .tabItem { Label("General", systemImage: "gearshape") }

            ModelsSettings()
                .tag("models")
            .tabItem { Label("Models", systemImage: "cpu") }

            EnginesSettings()
                .tag("engines")
            .tabItem { Label("Engines", systemImage: "server.rack") }

            SharingSettings()
                .tag("sharing")
            .tabItem { Label("Sharing", systemImage: "network") }

            UsageSettings()
                .tag("usage")
            .tabItem { Label("Usage", systemImage: "chart.bar") }

            RequestsView()
                .tag("requests")
            .tabItem { Label("Requests", systemImage: "list.bullet.rectangle") }

            BenchmarkView(bench: state.benchmark)
                .tag("benchmark")
            .tabItem { Label("Benchmark", systemImage: "speedometer") }

            ReviewLoopView(loop: state.reviewLoop)
                .tag("loop")
            .tabItem { Label("Review loop", systemImage: "arrow.triangle.2.circlepath") }

            StatsSettings()
                .tag("system")
            .tabItem { Label("System", systemImage: "gauge.with.dots.needle.33percent") }

            AboutView()
                .tag("about")
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 720, height: 760)
        .onDisappear { NSApp.setActivationPolicy(.accessory) }   // back to menu bar-only
        .task { await state.refreshInstalled(force: true) }
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("LLM Switcher").font(.title2.bold())
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .foregroundStyle(.secondary)
            Text("Use your oMLX and Splash models in Claude Desktop, one button to switch.")
                .multilineTextAlignment(.center)
            Text("© 2026 DePalo Consulting LLC").font(.caption).foregroundStyle(.secondary)
            if Updater.shared.isConfigured {
                Button("Check for Updates…") { Updater.shared.checkForUpdates() }
            } else {
                Text("Automatic updates aren't set up for this copy yet.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// General → oMLX: installed version, newer releases, and a safe one-click upgrade.
struct OMLXUpdateSection: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var updater: OMLXUpdater
    @AppStorage("omlx.devBuilds") private var devBuilds = false
    @State private var confirm: OMLXUpdater.Release?

    var body: some View {
        Section("oMLX") {
            LabeledContent("Installed", value: updater.installed)
            if let s = updater.latestStable { LabeledContent("Latest stable", value: "\(s.version) (\(s.date))") }
            if let d = updater.latestDev, d.isDev { LabeledContent("Latest development build", value: "\(d.version) (\(d.date))") }
            Toggle("Offer development builds", isOn: $devBuilds)
            HStack {
                if let next = updater.newer(includeDev: devBuilds) {
                    Button("Upgrade to \(next.version)…") { confirm = next }
                        .buttonStyle(.borderedProminent)
                        .disabled(updater.status != nil && updater.error == nil && !(updater.status ?? "").hasPrefix("oMLX \(updater.installed)"))
                } else if !updater.releases.isEmpty {
                    Text("Up to date").foregroundStyle(.secondary)
                }
                Spacer()
                Button(updater.checking ? "Checking…" : "Check now") { Task { await updater.check() } }.disabled(updater.checking)
            }
            if let s = updater.status { Text(s).font(.caption).foregroundStyle(.secondary) }
            if let e = updater.error { Text(e).font(.caption).foregroundStyle(.red) }
            Text("Upgrades are checked against GitHub's checksum, Apple notarization and oMLX's developer signature. LLM Switcher waits for running requests to finish, oMLX may ask you to confirm quitting, and the old version goes to the Trash.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Upgrade oMLX to \(confirm?.version ?? "")?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Upgrade") { if let r = confirm { state.upgradeOMLX(r) }; confirm = nil }
        } message: {
            Text("Downloads \(ByteCountFormatter.string(fromByteCount: confirm?.dmgSize ?? 0, countStyle: .file)) from oMLX's GitHub releases.\((confirm?.isDev ?? false) ? " This is a development build." : "") oMLX restarts, so anything using it pauses for a minute.")
        }
    }
}
