import SwiftUI

/// Models tab: a model's recommended settings from its makers, next to what's set now, with Apply.
struct BestConfigPanel: View {
    @EnvironmentObject var state: AppState
    let model: String
    let engine: EngineKind
    @State private var result: BestConfig.Result?
    @State private var looking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Recommended settings").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(looking ? "Looking…" : (result == nil ? "Find" : "Look again")) { find() }
                    .controlSize(.small).disabled(looking)
            }
            if let r = result {
                if let note = r.note { Text(note).font(.caption).foregroundStyle(.secondary) }
                if let base = r.baseModel { Text("Base model: \(base)").font(.caption).foregroundStyle(.secondary) }
                ForEach(r.recommendations) { rec in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Link(rec.source, destination: URL(string: rec.url)!).font(.caption)
                            Text(rec.summary).font(.caption.monospaced())
                        }
                        Spacer()
                        Button("Apply") { apply(rec) }.controlSize(.small)
                    }
                }
                if !r.recommendations.isEmpty {
                    Text("Now: \(current.summary.isEmpty ? "model defaults" : current.summary)").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                if let t = r.template { templateLine(t) }
                if !r.recommendations.isEmpty {
                    Toggle("Always use these (ignore what apps send)", isOn: Binding(
                        get: { state.preset(model).lockSampling },
                        set: { var p = state.preset(model); p.lockSampling = $0; state.setPreset(model, p) }))
                        .font(.caption)
                    Text("Published settings are a starting point: test the model, and keep yours if they work better.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private func templateLine(_ t: BestConfig.Template) -> some View {
        let levels = t.effortLevels.isEmpty ? "" : " · thinking levels: \(t.effortLevels.joined(separator: ", "))"
        let def = t.defaultEffort.map { " (default \($0))" } ?? ""
        Text("Thinking switch: \(t.thinkingSwitch ? "yes" : "no")\(levels)\(def)").font(.caption).foregroundStyle(.secondary)
        if let d = t.defaultEffort, ["xhigh", "max"].contains(d) {
            Text("Its default thinking level is \(d): it can think for tens of thousands of tokens. Set Thinking below to a lower level for everyday use.")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    /// What applies now: oMLX's own settings for oMLX models, LLM Switcher's preset otherwise.
    private var current: BestConfig.Recommendation {
        var c = BestConfig.Recommendation(source: "now", url: "")
        if engine == .omlx, let i = state.adminModel(model) {
            c.temperature = i.temperature; c.topP = i.topP; c.topK = i.topK
            c.minP = i.minP; c.presencePenalty = i.presencePenalty; c.repetitionPenalty = i.repetitionPenalty
        } else {
            let p = state.preset(model)
            c.temperature = p.temperature; c.topP = p.topP; c.topK = p.topK
            c.minP = p.minP; c.presencePenalty = p.presencePenalty; c.repetitionPenalty = p.repetitionPenalty
        }
        return c
    }

    private func find() {
        looking = true
        let cfg = state.config
        Task {
            result = await BestConfig.lookup(model, engine: engine, cfg)
            looking = false
        }
    }

    private func apply(_ r: BestConfig.Recommendation) {
        if engine == .omlx {
            // Only the values the source gives; the rest stay as they are.
            var changes: [String: Any] = [:]
            if let v = r.temperature { changes["temperature"] = v }
            if let v = r.topP { changes["top_p"] = v }
            if let v = r.topK { changes["top_k"] = v }
            if let v = r.minP { changes["min_p"] = v }
            if let v = r.presencePenalty { changes["presence_penalty"] = v }
            if let v = r.repetitionPenalty { changes["repetition_penalty"] = v }
            state.setOMLX(model, changes)
        } else {
            var p = state.preset(model)
            if let v = r.temperature { p.temperature = v }
            if let v = r.topP { p.topP = v }
            if let v = r.topK { p.topK = v }
            if let v = r.minP { p.minP = v }
            if let v = r.presencePenalty { p.presencePenalty = v }
            if let v = r.repetitionPenalty { p.repetitionPenalty = v }
            state.setPreset(model, p)
        }
    }
}
