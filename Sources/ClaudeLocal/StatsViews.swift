import Charts
import SwiftUI

private let coreColors: [Color] = [.orange, .blue, .purple, .teal]

private func gb(_ bytes: Int64) -> String { String(format: "%.1f GB", Double(bytes) / 1_073_741_824) }
private func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

private func uptimeString(_ t: TimeInterval) -> String {
    let h = Int(t) / 3600, m = (Int(t) % 3600) / 60
    return h >= 24 ? "\(h / 24)d \(h % 24)h" : "\(h)h \(m)m"
}

private func thermalString(_ s: ProcessInfo.ThermalState) -> (String, Color) {
    switch s {
    case .nominal: return ("Nominal", .secondary)
    case .fair: return ("Fair", .yellow)
    case .serious: return ("Serious (slowing down)", .orange)
    case .critical: return ("Critical (throttled)", .red)
    @unknown default: return ("Unknown", .secondary)
    }
}

struct UsageBar: View {
    let value: Double
    let color: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color).frame(width: max(3, g.size.width * min(1, max(0, value))))
            }
        }
        .frame(height: 6)
    }
}

struct LabeledBar: View {
    let label: String
    let value: Double
    let detail: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack { Text(label).font(.callout.weight(.medium)); Spacer(); Text(detail).font(.callout.monospacedDigit()) }
            UsageBar(value: value, color: color)
        }
    }
}

struct Sparkline: View {
    let series: [(name: String, values: [Double], color: Color)]
    var body: some View {
        Chart {
            ForEach(series, id: \.name) { s in
                ForEach(Array(s.values.enumerated()), id: \.offset) { i, v in
                    LineMark(x: .value("t", i), y: .value("use", v), series: .value("s", s.name))
                        .foregroundStyle(s.color)
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartYScale(domain: 0...1)
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .frame(height: 44)
    }
}

/// Settings → System: the full panel, modelled on oMLX's System Stats.
struct StatsSettings: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        let s = state.system
        Form {
            Section("CPU") {
                ForEach(Array(s.coreGroups.enumerated()), id: \.offset) { i, g in
                    LabeledBar(label: g.name, value: g.usage, detail: pct(g.usage), color: coreColors[i % coreColors.count])
                }
                Sparkline(series: s.coreGroups.indices.map { i in
                    (s.coreGroups[i].name, i < state.cpuHistory.count ? state.cpuHistory[i] : [], coreColors[i % coreColors.count])
                })
                let t = thermalString(s.thermal)
                LabeledContent("Thermal") { Text(t.0).foregroundStyle(t.1) }
                LabeledContent("Load average", value: String(format: "%.2f · %.2f · %.2f", s.load.0, s.load.1, s.load.2))
                LabeledContent("Uptime", value: uptimeString(s.uptime))
            }
            Section("GPU") {
                LabeledBar(label: "GPU", value: s.gpu ?? 0, detail: s.gpu.map(pct) ?? "n/a", color: .green)
                if let m = s.gpuMemory {
                    LabeledBar(label: "GPU memory", value: Double(m) / Double(max(1, s.total)), detail: "\(gb(m)) in use", color: .cyan)
                }
                Sparkline(series: [("GPU", state.gpuHistory, .green)])
            }
            Section("Memory") {
                HStack {
                    Text("\(gb(s.used)) / \(gb(s.total))").font(.title3.monospacedDigit().weight(.semibold))
                    Spacer()
                    Text(pct(Double(s.used) / Double(max(1, s.total)))).foregroundStyle(.secondary)
                }
                MemoryBar(s: s)
                MemoryLegend(color: .blue, name: "Wired (models live here)", value: s.wired)
                MemoryLegend(color: .red, name: "Active", value: s.active)
                MemoryLegend(color: .purple, name: "Compressed", value: s.compressed)
                MemoryLegend(color: .gray, name: "Free", value: s.free)
            }
            Section("oMLX serving") {
                if let v = state.serving {
                    LabeledContent("Requests this session", value: "\(v.requests)")
                    LabeledContent("Running now", value: "\(v.activeRequests) running · \(v.waitingRequests) waiting")
                    LabeledContent("Average reading speed", value: String(format: "%.0f tokens/s", v.avgPrefill))
                    LabeledContent("Average writing speed", value: String(format: "%.0f tokens/s", v.avgGeneration))
                    LabeledContent("Reused from cache", value: String(format: "%.0f%% of prompt tokens", v.cacheEfficiency))
                    LabeledContent("Tokens", value: "\(v.promptTokens.formatted()) in · \(v.completionTokens.formatted()) out")
                    if v.modelMemoryMax > 0 {
                        LabeledBar(label: "Model memory", value: Double(v.modelMemoryUsed) / Double(v.modelMemoryMax),
                                   detail: "\(gb(v.modelMemoryUsed)) of \(gb(v.modelMemoryMax))", color: .indigo)
                    }
                    ForEach(v.loaded.filter { $0.size > 0 }, id: \.id) { m in
                        HStack {
                            Circle().fill(m.active > 0 ? Color.green : Color.secondary).frame(width: 7, height: 7)
                            Text(m.id).font(.caption.monospaced()).lineLimit(1)
                            Spacer()
                            Text(m.active > 0 ? "\(m.active) running" : "idle \(Int(m.idle / 60)) min").font(.caption).foregroundStyle(.secondary)
                            Text(gb(m.size)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Text(state.omlxRunning ? "Reading oMLX's stats…" : "oMLX isn't running.").foregroundStyle(.secondary)
                }
            }
            Section {
                if state.cacheScanning && state.cache.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) }
                }
                let total = state.cache.reduce(Int64(0)) { $0 + $1.bytes }
                if !state.cache.isEmpty {
                    LabeledContent("Total on SSD", value: gb(total))
                }
                ForEach(state.cache) { e in
                    HStack {
                        Text(e.model).font(.callout.monospaced()).lineLimit(1)
                        if !state.models.contains(e.model) && e.model != "Unknown" { Badge(text: "model removed", color: .orange) }
                        Spacer()
                        Text(gb(e.bytes)).font(.caption.monospaced()).foregroundStyle(.secondary)
                        let inUse = state.adminModel(e.model)?.loaded == true
                        Button("Clear") { state.clearCache(e.model) }.controlSize(.small)
                            .disabled(inUse)
                            .help(inUse ? "Unload this model first (Models tab): oMLX is using these files." : "Move this model's saved prompts to the Trash")
                    }
                }
                Text("oMLX saves past prompts here so long chats answer quickly the next time. Clearing a model's share is safe; it rebuilds as you use it. Cleared files go to the Trash.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                HStack {
                    Text("Prompt cache")
                    Spacer()
                    Button("Refresh") { state.scanCache() }.buttonStyle(.link).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { state.scanCache(); Task { await state.refreshAdmin() } }
    }
}

struct MemoryBar: View {
    let s: SystemSample
    var body: some View {
        GeometryReader { g in
            let total = Double(max(1, s.total))
            HStack(spacing: 1) {
                Rectangle().fill(.blue).frame(width: g.size.width * Double(s.wired) / total)
                Rectangle().fill(.red).frame(width: g.size.width * Double(s.active) / total)
                Rectangle().fill(.purple).frame(width: max(2, g.size.width * Double(s.compressed) / total))
                Rectangle().fill(Color.primary.opacity(0.08))
            }
            .clipShape(Capsule())
        }
        .frame(height: 8)
    }
}

struct MemoryLegend: View {
    let color: Color
    let name: String
    let value: Int64
    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(name)
            Spacer()
            Text(gb(value)).font(.callout.monospacedDigit())
        }
    }
}

/// Compact live strip for the menu bar panel.
struct StatsStrip: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        let s = state.system
        let cpu = s.coreGroups.isEmpty ? 0 : s.coreGroups.map(\.usage).reduce(0, +) / Double(s.coreGroups.count)
        HStack(spacing: 12) {
            MiniStat(label: "CPU", value: cpu, color: .blue)
            MiniStat(label: "GPU", value: s.gpu ?? 0, color: .green)
            MiniStat(label: "Memory", value: Double(s.used) / Double(max(1, s.total)), color: .purple)
            if let v = state.serving, v.activeRequests > 0 {
                Text("\(v.activeRequests) running").font(.caption2).foregroundStyle(.green)
            }
        }
    }
}

struct MiniStat: View {
    let label: String
    let value: Double
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(label).font(.caption2).foregroundStyle(.secondary)
                Text(pct(value)).font(.caption2.monospacedDigit())
            }
            UsageBar(value: value, color: color).frame(width: 70)
        }
    }
}
