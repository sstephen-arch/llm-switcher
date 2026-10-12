import SwiftUI

/// Settings → Benchmark: test any model on any engine, and compare the results side by side.
struct BenchmarkView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject var bench: Benchmark
    @State private var model = ""
    @State private var options = Benchmark.Options()
    @State private var selection = Set<BenchResult.ID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Form {
                Picker("Model", selection: $model) {
                    Text("Choose…").tag("")
                    ForEach(EngineKind.allCases, id: \.self) { k in
                        let list = state.models.filter { state.engineOf[$0] == k }
                        if !list.isEmpty {
                            Section(k.label) { ForEach(list, id: \.self) { Text($0).tag($0) } }
                        }
                    }
                    if !state.stoppedModels.isEmpty {
                        Section("Engine stopped (starts when tested)") {
                            ForEach(state.stoppedModels, id: \.self) { Text($0).tag($0) }
                        }
                    }
                }
                HStack {
                    Toggle("Speed", isOn: $options.speed)
                    Toggle("Tool call", isOn: $options.tools)
                    Picker("Coding", selection: $options.coding) {
                        Text("None").tag("none"); Text("6 hard problems").tag("hard"); Text("All 12").tag("all")
                    }.frame(width: 220)
                }
                Picker("Thinking for coding", selection: $options.thinking) {
                    Text("Model's default").tag("default"); Text("Off").tag("off")
                    Text("Low").tag("low"); Text("Medium").tag("medium"); Text("High").tag("high")
                }
                Text("Runs through LLM Switcher, so each model's tuned settings apply as they do for Claude. Speed tests run with thinking off. Coding answers are graded by hidden tests in a sandbox (no network, no file access outside a temp folder). With thinking on, coding can take 20 minutes or more. A stopped engine starts when its model is tested.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if bench.running {
                        ProgressView().controlSize(.small)
                        Button("Stop") { bench.stop() }
                    } else {
                        Button("Run benchmark") { bench.start(model: model, options: options, gateway: state.config.port) }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.isEmpty || (!options.speed && !options.tools && options.coding == "none"))
                    }
                    Spacer()
                    Button("Open results folder") {
                        try? FileManager.default.createDirectory(at: Benchmark.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Benchmark.folder)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: 300)

            if !bench.steps.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(bench.steps.enumerated()), id: \.offset) { i, s in
                                Text(s).font(.caption.monospaced()).textSelection(.enabled).id(i)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 110)
                    .onChange(of: bench.steps.count) { proxy.scrollTo($0 - 1) }
                }
            }

            Text("Results").font(.headline)
            Table(bench.results, selection: $selection) {
                TableColumn("Date") { r in Text(r.date, format: .dateTime.month().day().hour().minute()) }.width(85)
                TableColumn("Model") { r in Text(r.model).lineLimit(1).help(r.model) }.width(min: 140, ideal: 200)
                TableColumn("First word") { r in Text(f(r.firstWord, "s", 1)) }.width(65)
                TableColumn("Write") { r in Text(f(r.writeSpeed, "", 0)) }.width(45)
                TableColumn("Read") { r in Text(f(r.readSpeed, "", 0) + (r.readRecall == false ? " ✗" : "")) }.width(55)
                TableColumn("4 at once") { r in Text(f(r.parallelSpeed, "", 0)) }.width(60)
                TableColumn("Tool") { r in Text(r.toolCall.map { $0 ? "✓" : "✗" } ?? "–") }.width(35)
                TableColumn("Coding") { r in Text(r.codingPassed.map { "\($0)/\(r.codingTotal ?? 0)" } ?? "–").help(details(r)) }.width(55)
                TableColumn("Thinking", value: \.thinking).width(65)
                TableColumn("Time") { r in Text(String(format: "%.0f min", r.minutes)) }.width(50)
            }
            .contextMenu(forSelectionType: BenchResult.ID.self) { ids in
                Button("Delete", role: .destructive) { for r in bench.results where ids.contains(r.id) { bench.delete(r) } }
            }
            Text("Speeds are tokens per second. Read = prompt reading speed (✗ = missed the hidden code word). Hover over Coding for each problem's result; right-click a row to delete it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
    }

    private func f(_ v: Double?, _ unit: String, _ digits: Int) -> String {
        v.map { String(format: "%.\(digits)f", $0) + unit } ?? "–"
    }

    private func details(_ r: BenchResult) -> String {
        r.codingDetails.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
    }
}
