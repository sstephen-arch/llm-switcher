import SwiftUI

/// Every finished request, kept on disk as one JSON line each (numbers only, never prompt or
/// reply text) so the Requests tab survives restarts. Trimmed to the last few thousand.
enum RequestLog {
    static let url = Log.url.deletingLastPathComponent().appendingPathComponent("requests.jsonl")
    static let keep = 2000
    private static let queue = DispatchQueue(label: "claudelocal.requestlog")

    static func append(_ a: Gateway.Activity) {
        queue.async {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
            guard var line = try? enc.encode(a) else { return }
            line.append(0x0A)
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(line); try? h.close()
            } else {
                try? line.write(to: url)
            }
            // Past ~5 MB, keep only the newest lines.
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 5_000_000 {
                let all = load()
                let enc2 = JSONEncoder(); enc2.dateEncodingStrategy = .iso8601
                let data = all.prefix(keep).reversed().compactMap { try? enc2.encode($0) }
                    .reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Newest first.
    static func load() -> [Gateway.Activity] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let lines = text.split(separator: "\n").suffix(keep)
        return lines.compactMap { try? dec.decode(Gateway.Activity.self, from: Data($0.utf8)) }.reversed()
    }

    static func clear() { queue.async { try? FileManager.default.removeItem(at: url) } }
}

/// Settings → Requests: what each request cost, so engines and models can be compared on real use.
struct RequestsView: View {
    @EnvironmentObject var state: AppState
    @State private var engine = ""
    @State private var model = ""
    @State private var errorsOnly = false
    @State private var confirmClear = false

    private var rows: [Gateway.Activity] {
        state.activity.filter {
            (engine.isEmpty || $0.engine == engine) && (model.isEmpty || $0.model == model) && (!errorsOnly || $0.status >= 400)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Engine", selection: $engine) {
                    Text("All engines").tag("")
                    ForEach(EngineKind.allCases, id: \.self) { Text($0.label).tag($0.rawValue) }
                }.frame(width: 200)
                Picker("Model", selection: $model) {
                    Text("All models").tag("")
                    ForEach(Array(Set(state.activity.map(\.model))).sorted(), id: \.self) { Text($0).tag($0) }
                }.frame(width: 300)
                Toggle("Errors only", isOn: $errorsOnly)
                Spacer()
                Button("Clear…") { confirmClear = true }
            }
            Text("By model (typical values)").font(.headline)
            Table(summaries) {
                TableColumn("Model") { s in Text(s.model).lineLimit(1).help(s.model) }.width(min: 160, ideal: 220)
                TableColumn("Engine", value: \.engine).width(70)
                TableColumn("Requests") { s in Text("\(s.count)\(s.errors > 0 ? " (\(s.errors) failed)" : "")") }.width(90)
                TableColumn("First word") { s in Text(fmt(s.firstWord, "s", 1)) }.width(70)
                TableColumn("Reading") { s in Text(fmt(s.read, " t/s", 0)) }.width(80)
                TableColumn("Writing") { s in Text(fmt(s.write, " t/s", 0)) }.width(70)
                TableColumn("Cache reuse") { s in Text(s.cacheShare.map { String(format: "%.0f%%", $0 * 100) } ?? "–") }.width(80)
            }
            .frame(height: 150)
            Text("Recent requests").font(.headline)
            Table(rows) {
                TableColumn("Time") { a in Text(a.date, format: .dateTime.hour().minute().second()) }.width(70)
                TableColumn("Who") { a in Text(a.client).lineLimit(1) }.width(min: 70, ideal: 110)
                TableColumn("Model") { a in Text(a.model).lineLimit(1).help(a.model) }.width(min: 120, ideal: 180)
                TableColumn("Status") { a in Text("\(a.status)").foregroundStyle(a.status >= 400 ? .red : .primary) }.width(45)
                TableColumn("In (cached)") { a in Text(a.cachedTokens > 0 ? "\(a.inputTokens) (\(a.cachedTokens))" : "\(a.inputTokens)") }.width(90)
                TableColumn("Out") { a in Text("\(a.outputTokens)") }.width(50)
                TableColumn("First word") { a in Text(fmt(a.firstWord, "s", 1)) }.width(65)
                TableColumn("Read") { a in Text(fmt(a.readSpeed, "", 0)) }.width(50)
                TableColumn("Write") { a in Text(fmt(a.writeSpeed, "", 0)) }.width(50)
                TableColumn("Total") { a in Text(String(format: "%.1fs", a.seconds)) }.width(55)
            }
            Text("First word = waiting before anything comes back (mostly reading the prompt). Read and write speeds are tokens per second; streamed requests only. Only numbers are kept, never prompts or replies.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .confirmationDialog("Clear the request history?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive) { state.clearRequests() }
        }
    }

    struct Summary: Identifiable {
        var id: String { model }
        let model: String
        let engine: String
        let count: Int
        let errors: Int
        let firstWord: Double?
        let read: Double?
        let write: Double?
        let cacheShare: Double?
    }

    private var summaries: [Summary] {
        Dictionary(grouping: rows, by: \.model).map { model, list in
            let input = list.reduce(0) { $0 + $1.inputTokens }
            let cached = list.reduce(0) { $0 + $1.cachedTokens }
            return Summary(model: model, engine: EngineKind(rawValue: list[0].engine)?.label ?? "",
                           count: list.count, errors: list.filter { $0.status >= 400 }.count,
                           firstWord: median(list.compactMap(\.firstWord)), read: median(list.compactMap(\.readSpeed)),
                           write: median(list.compactMap(\.writeSpeed)),
                           cacheShare: input > 0 ? Double(cached) / Double(input) : nil)
        }
        .sorted { $0.count > $1.count }
    }

    private func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    private func fmt(_ v: Double?, _ unit: String, _ digits: Int) -> String {
        v.map { String(format: "%.\(digits)f", $0) + unit } ?? "–"
    }
}
