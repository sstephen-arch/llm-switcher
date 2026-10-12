import AppKit
import Charts
import SwiftUI

// MARK: - Models tab

struct ModelsSettings: View {
    @EnvironmentObject var state: AppState
    @State private var query = ""
    @State private var results: [HuggingFace.Result] = []
    @State private var searching = false

    var body: some View {
        Form {
            Section("Claude slots (\(state.viewEngine.label))") {
                SlotPickers()
                Text("Switch engines in the menu bar. Each engine keeps its own picks.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if state.omlxModels.isEmpty {
                    Text(state.omlxRunning ? "No models yet. Find one below." : "oMLX isn't running.").foregroundStyle(.secondary)
                }
                ForEach(state.omlxModels, id: \.self) { m in InstalledModelRow(model: m) }
            } header: {
                HStack {
                    Text("Installed in oMLX")
                    Spacer()
                    Button("Open oMLX dashboard") { NSWorkspace.shared.open(URL(string: state.config.upstream + "/admin")!) }
                        .buttonStyle(.link).font(.caption)
                }
            }

            ForEach(EngineKind.allCases.filter { $0 != .omlx }, id: \.self) { k in
                let list = state.models.filter { state.engineOf[$0] == k }
                if !list.isEmpty {
                    Section("Running in \(k.label)") {
                        ForEach(list, id: \.self) { m in EngineModelRow(model: m, engine: k) }
                        Text("Engine settings (port, context, memory) are in the Engines tab.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Get more models") {
                HStack {
                    TextField("Search Hugging Face for MLX models, e.g. Qwen3.8 MTP", text: $query)
                        .onSubmit(search)
                    Button("Search", action: search).disabled(query.isEmpty || searching)
                }
                if searching { ProgressView().controlSize(.small) }
                ForEach(results) { r in SearchResultRow(result: r) }
                Text("Each result is checked before you download: its size against this Mac's memory, and whether this oMLX can run it. Builds named oQ…-mtp are made for oMLX and run fastest.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !state.downloads.isEmpty {
                Section("Downloads") {
                    ForEach(state.downloads) { d in DownloadRow(download: d) }
                }
            }
        }
        .formStyle(.grouped)
        .task { await state.refreshAdmin() }
    }

    private func search() {
        searching = true
        Task { results = await HuggingFace.search(query); searching = false }
    }
}

struct Badge: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text).font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }
}

private func fitColor(_ f: ModelCheck.Fit) -> Color {
    switch f {
    case .fits: return .green
    case .tight: return .yellow
    case .needsLimitRaised: return .orange
    case .tooBig: return .red
    }
}

struct SearchResultRow: View {
    @EnvironmentObject var state: AppState
    let result: HuggingFace.Result
    @State private var check: ModelCheck?
    @State private var checked = false
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.id).font(.callout.monospaced()).lineLimit(1)
                    Text("\(result.downloads.formatted()) downloads · \(result.likes) likes · updated \(result.updated)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Link("Page", destination: URL(string: "https://huggingface.co/\(result.id)")!).font(.caption)
                Button("Download") {
                    if let c = check, c.fit == .fits, c.runsInOMLX, !c.helper { state.download(result.id) } else { confirm = true }
                }
                .disabled(state.downloads.contains { $0.repo == result.id && !$0.failed })
            }
            if let c = check {
                HStack(spacing: 6) {
                    Badge(text: ByteCountFormatter.string(fromByteCount: c.size, countStyle: .file))
                    Badge(text: ModelCheck.describe(c.fit), color: fitColor(c.fit))
                    if !c.quant.isEmpty { Badge(text: c.quant) }
                    if c.hasMTP { Badge(text: "MTP speed-up", color: .blue) }
                    if c.helper { Badge(text: "Helper, not a chat model", color: .orange) }
                    Badge(text: c.runsInOMLX ? "Runs in oMLX" : "May not run in oMLX", color: c.runsInOMLX ? .green : .red)
                }
                ForEach(c.problems, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.red) }
            } else if checked {
                Text("Couldn't check this repo.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("Checking size and compatibility…").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .task(id: result.id) {
            check = await HuggingFace.check(result.id, ceiling: state.memoryCeiling)
            checked = true
        }
        .confirmationDialog("Download \(result.id)?", isPresented: $confirm) {
            Button("Download anyway") { state.download(result.id) }
        } message: {
            Text(confirmText)
        }
    }

    private var confirmText: String {
        guard let c = check else { return "It couldn't be checked first. Check its page for size and format." }
        var lines = ["It's \(ByteCountFormatter.string(fromByteCount: c.size, countStyle: .file)). \(ModelCheck.describe(c.fit))."]
        switch c.fit {
        case .tight: lines.append("It will load, but long chats may run short of memory.")
        case .needsLimitRaised: lines.append("Before loading it, raise the limit in Terminal (resets on restart):\n\(ModelCheck.raiseLimitCommand(ram: state.ram))\nEven then oMLX may keep part of it on the SSD, which is slower.")
        case .tooBig: lines.append("It won't fit in this Mac's memory.")
        case .fits: break
        }
        if c.helper { lines.append("This is a speed-up helper for another model, not a model you can chat with.") }
        lines += c.problems
        return lines.joined(separator: "\n\n")
    }
}

struct InstalledModelRow: View {
    @EnvironmentObject var state: AppState
    let model: String
    @State private var expanded = false
    @State private var confirmTrash = false
    @State private var warnings: [String] = []

    var body: some View {
        let info = state.adminModel(model)
        DisclosureGroup(isExpanded: $expanded) {
            if !warnings.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("oMLX warnings").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    ForEach(warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                .padding(.bottom, 4)
            }
            if let info { OMLXSettingsEditor(info: info) }
            BestConfigPanel(model: model, engine: .omlx)
            Divider()
            Text("LLM Switcher settings").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            PresetEditor(model: model)
            HStack {
                Button("Test speed") { state.testSpeed(model) }
                if let s = state.speed[model] { Text(s).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if let info {
                    if info.loaded { Button("Unload") { state.unload(model) } }
                    else { Button("Load now") { state.load(model) }.disabled(info.loading) }
                }
                Button("Move to Trash…", role: .destructive) { confirmTrash = true }
            }
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(model).font(.callout.monospaced()).lineLimit(1)
                    Spacer()
                    let slots = Slots.all.filter { state.config.slots[$0.id] == model }.map(\.label)
                    if !slots.isEmpty { Text(slots.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                    Text(ByteCountFormatter.string(fromByteCount: OMLX.sizeOnDisk(model), countStyle: .file))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let info {
                    HStack(spacing: 5) {
                        Badge(text: info.engineType.uppercased())
                        if info.loading { Badge(text: "Loading", color: .yellow) }
                        else if info.loaded { Badge(text: "Loaded", color: .green) }
                        if info.mtpOn { Badge(text: "MTP on", color: .blue) }
                        else if info.mtpCompatible { Badge(text: "MTP available", color: .orange) }
                        if info.pinned { Badge(text: "Kept loaded") }
                        if let c = info.contextWindow { Badge(text: "ctx \(c / 1024)k") }
                        else if info.contextLength > 0 { Badge(text: "ctx \(info.contextLength / 1024)k") }
                        if info.pleForcedToSSD { Badge(text: "Part on SSD (slower)", color: .orange) }
                        if !warnings.isEmpty { Badge(text: "\(warnings.count) warning\(warnings.count == 1 ? "" : "s")", color: .orange) }
                    }
                }
            }
        }
        .task(id: model) { warnings = await Task.detached { OMLXAdmin.warnings(for: model) }.value }
        .confirmationDialog("Move \(model) to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { state.trashModel(model) }
        } message: { Text("It's unloaded first, then its folder, its oMLX settings and its cache files go to the Trash. You can put them back until you empty it. Any Claude slot using it is cleared.") }
    }
}

/// oMLX's own per-model settings (the dashboard's Model Settings page), saved through its admin API.
struct OMLXSettingsEditor: View {
    @EnvironmentObject var state: AppState
    let info: OMLXAdmin.Model

    private static let contexts = [0, 8192, 16384, 32768, 65536, 131072, 262144]
    private static let ttls = [0, 300, 900, 1800, 3600, 7200]

    /// Preset sizes up to the model's limit, plus whatever is set now (e.g. 100k from oMLX's dashboard).
    private var contextChoices: [Int] {
        var c = Self.contexts.dropFirst().filter { info.contextLength == 0 || $0 <= info.contextLength }
        if let cur = info.contextWindow, cur > 0, !c.contains(cur) { c.append(cur); c.sort() }
        return c
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("oMLX settings").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Toggle("MTP speed-up", isOn: Binding(get: { info.mtpOn }, set: { state.setOMLX(info.id, ["mtp_enabled": $0]) }))
                .disabled(!info.mtpCompatible)
            if !info.mtpCompatible {
                Text(info.mtpReason.isEmpty ? "This model has no MTP head." : info.mtpReason).font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Keep loaded (never unload when idle)", isOn: Binding(get: { info.pinned }, set: { state.setOMLX(info.id, ["is_pinned": $0]) }))
            Picker("Context window", selection: Binding(get: { info.contextWindow ?? 0 }, set: {
                state.setOMLX(info.id, ["max_context_window": $0 == 0 ? NSNull() : $0])
            })) {
                Text(info.contextLength > 0 ? "Model default (\(info.contextLength / 1024)k)" : "Model default").tag(0)
                ForEach(contextChoices, id: \.self) { Text("\($0 / 1024)k").tag($0) }
            }
            Picker("Unload after idle", selection: Binding(get: { info.ttl ?? 0 }, set: {
                state.setOMLX(info.id, ["ttl_seconds": $0 == 0 ? NSNull() : $0])
            })) {
                Text("oMLX default").tag(0)
                ForEach(Self.ttls.dropFirst(), id: \.self) { Text($0 < 3600 ? "\($0 / 60) min" : "\($0 / 3600) h").tag($0) }
            }
            if info.thinkingModes.count > 1 {
                Picker("Thinking (oMLX default)", selection: Binding(get: { info.thinkingOn.map { $0 ? 1 : 2 } ?? 0 }, set: {
                    state.setOMLX(info.id, ["enable_thinking": $0 == 0 ? NSNull() : ($0 == 1)])
                })) {
                    Text("Model default").tag(0); Text("On").tag(1); Text("Off").tag(2)
                }
            }
            HStack {
                SamplingField(label: "Temperature", value: info.temperature) { state.setOMLX(info.id, ["temperature": $0.map { $0 as Any } ?? NSNull()]) }
                SamplingField(label: "Top P", value: info.topP) { state.setOMLX(info.id, ["top_p": $0.map { $0 as Any } ?? NSNull()]) }
                SamplingField(label: "Top K", value: info.topK.map(Double.init)) { state.setOMLX(info.id, ["top_k": $0.map { Int($0) as Any } ?? NSNull()]) }
            }
            Text("Blank sampling fields use the model's own defaults. These apply to every app that uses this model through oMLX.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct SamplingField: View {
    let label: String
    let value: Double?
    let commit: (Double?) -> Void
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            TextField("default", text: $text)
                .textFieldStyle(.roundedBorder).frame(width: 80)
                .onSubmit {
                    let t = text.trimmingCharacters(in: .whitespaces)
                    if t.isEmpty { commit(nil) }
                    else if let v = Double(t.replacingOccurrences(of: ",", with: ".")) { commit(v) }
                    else { text = value.map { String($0) } ?? "" }      // not a number: put the old value back
                }
        }
        .onAppear { text = Self.show(value, label) }
        .onChange(of: value) { text = Self.show($0, label) }      // e.g. after Apply recommended
    }

    static func show(_ value: Double?, _ label: String) -> String {
        value.map { $0 == $0.rounded() && label == "Top K" ? String(Int($0)) : String($0) } ?? ""
    }
}

struct EngineModelRow: View {
    @EnvironmentObject var state: AppState
    let model: String
    let engine: EngineKind
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            BestConfigPanel(model: model, engine: engine)
            Text("LLM Switcher settings").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            PresetEditor(model: model, sampling: true)
            HStack {
                Button("Test speed") { state.testSpeed(model) }
                if let s = state.speed[model] { Text(s).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Text(model).font(.callout.monospaced()).lineLimit(1)
                Badge(text: engine.label.uppercased(), color: .blue)
                Spacer()
                let slots = Slots.all.filter { state.config.slots[$0.id] == model }.map(\.label)
                if !slots.isEmpty { Text(slots.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

struct PresetEditor: View {
    @EnvironmentObject var state: AppState
    let model: String
    /// Show sampling defaults (top-p, top-k …). oMLX models keep these in oMLX's own settings.
    var sampling = false

    var body: some View {
        let p = state.preset(model)
        let set: (ModelPreset) -> Void = { state.setPreset(model, $0) }
        VStack(alignment: .leading, spacing: 8) {
            Picker("Thinking", selection: Binding(get: { p.thinking }, set: { var q = p; q.thinking = $0; set(q) })) {
                Text("Leave to the app").tag("default")
                Text("Off (fastest)").tag("off")
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High (most careful)").tag("high")
            }
            Stepper(value: Binding(get: { p.minOutputTokens }, set: { var q = p; q.minOutputTokens = max(0, $0); set(q) }), in: 0...65536, step: 1024) {
                Text("Minimum reply length: \(p.minOutputTokens == 0 ? "leave to the app" : "\(p.minOutputTokens) tokens")")
            }
            HStack {
                Toggle("Default temperature", isOn: Binding(get: { p.temperature != nil }, set: { var q = p; q.temperature = $0 ? 0.6 : nil; set(q) }))
                if let t = p.temperature {
                    Slider(value: Binding(get: { t }, set: { var q = p; q.temperature = ($0 * 20).rounded() / 20; set(q) }), in: 0...1.5)
                    Text(String(format: "%.2f", t)).font(.caption.monospaced()).frame(width: 36)
                }
            }
            if sampling {
                HStack {
                    SamplingField(label: "Top P", value: p.topP) { v in var q = p; q.topP = v; set(q) }
                    SamplingField(label: "Top K", value: p.topK.map(Double.init)) { v in var q = p; q.topK = v.map { Int($0) }; set(q) }
                    SamplingField(label: "Min P", value: p.minP) { v in var q = p; q.minP = v; set(q) }
                    SamplingField(label: "Presence penalty", value: p.presencePenalty) { v in var q = p; q.presencePenalty = v; set(q) }
                    SamplingField(label: "Repetition penalty", value: p.repetitionPenalty) { v in var q = p; q.repetitionPenalty = v; set(q) }
                }
                Text("Used when an app doesn't send its own. Blank = the model's default. Qwen3.8 thinking: temperature 1.0, top P 0.95, top K 20, min P 0; raise presence penalty to 1.5 if it loops.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Picker("Backup model", selection: Binding(get: { p.fallback ?? "" }, set: { var q = p; q.fallback = $0.isEmpty ? nil : $0; set(q) })) {
                Text("None").tag("")
                ForEach(state.models.filter { $0 != model }, id: \.self) { Text($0).tag($0) }
            }
            Text("Used when this model isn't available, or its engine fails on it before replying.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DownloadRow: View {
    @ObservedObject var download: ModelDownload
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(download.repo).font(.callout.monospaced()).lineLimit(1)
                Spacer()
                if !download.finished && !download.failed { Button("Cancel") { download.cancel() }.controlSize(.small) }
            }
            if !download.finished && !download.failed { ProgressView(value: download.fraction) }
            Text("\(download.state) — \(ByteCountFormatter.string(fromByteCount: download.received, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: download.total, countStyle: .file))")
                .font(.caption).foregroundStyle(download.failed ? .red : .secondary).lineLimit(2)
        }
    }
}

// MARK: - Usage tab

struct UsageSettings: View {
    @EnvironmentObject var state: AppState
    @State private var groupBy = "client"
    @State private var confirmClear = false

    private var rows: [UsageRow] { state.usage }

    var body: some View {
        Form {
            Section("Last 30 days") {
                Picker("Show by", selection: $groupBy) {
                    Text("Person").tag("client"); Text("Model").tag("model")
                }.pickerStyle(.segmented)
                if rows.isEmpty {
                    Text("No usage yet.").foregroundStyle(.secondary)
                } else {
                    Chart(rows) { r in
                        BarMark(x: .value("Day", r.day), y: .value("Tokens", r.inputTokens + r.outputTokens))
                            .foregroundStyle(by: .value(groupBy == "client" ? "Person" : "Model", groupBy == "client" ? r.client : r.model))
                    }
                    .frame(height: 180)
                }
            }
            Section("Totals") {
                let groups = Dictionary(grouping: rows) { groupBy == "client" ? $0.client : $0.model }
                ForEach(groups.keys.sorted(), id: \.self) { k in
                    let g = groups[k] ?? []
                    let req = g.reduce(0) { $0 + $1.requests }, err = g.reduce(0) { $0 + $1.errors }
                    let tin = g.reduce(0) { $0 + $1.inputTokens }, tout = g.reduce(0) { $0 + $1.outputTokens }
                    HStack {
                        Text(k).lineLimit(1)
                        Spacer()
                        Text("\(req) requests\(err > 0 ? " (\(err) failed)" : "") · \(tin.formatted()) in · \(tout.formatted()) out")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Text("Only counts are kept, never prompts or replies. \"Claude (this Mac)\" is your own Claude Desktop.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Clear usage history…", role: .destructive) { confirmClear = true }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear all usage history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { UsageStore.shared.clear() }
        }
    }
}
