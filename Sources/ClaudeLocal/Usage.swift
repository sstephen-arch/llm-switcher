import Foundation

/// Daily usage totals per client and model, kept at ~/Library/Application Support/ClaudeLocal/usage.json.
/// Only counts and token totals are stored: never prompts or replies.
struct UsageRow: Codable, Identifiable, Hashable {
    var day: String          // yyyy-MM-dd, local time
    var client: String       // client name ("Claude (this Mac)" for the local gateway)
    var model: String
    var requests: Int = 0
    var errors: Int = 0
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var seconds: Double = 0
    var id: String { "\(day)|\(client)|\(model)" }
}

final class UsageStore {
    static let shared = UsageStore()
    static let url = AppConfig.directory.appendingPathComponent("usage.json")
    private let queue = DispatchQueue(label: "claudelocal.usage")
    private var rows: [String: UsageRow] = [:]
    private var dirty = false
    var onChange: (() -> Void)?

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    init() {
        if let data = try? Data(contentsOf: Self.url),
           let list = try? JSONDecoder().decode([UsageRow].self, from: data) {
            rows = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        }
        // Write at most every few seconds rather than on every request.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.flush() }
    }

    func record(client: String, model: String, status: Int, input: Int, output: Int, seconds: Double) {
        queue.async {
            let day = Self.dayFormat.string(from: Date())
            let id = "\(day)|\(client)|\(model)"
            var row = self.rows[id] ?? UsageRow(day: day, client: client, model: model)
            row.requests += 1
            if status >= 400 { row.errors += 1 }
            row.inputTokens += input
            row.outputTokens += output
            row.seconds += seconds
            self.rows[id] = row
            self.dirty = true
            DispatchQueue.main.async { self.onChange?() }
        }
    }

    func snapshot(days: Int = 30) -> [UsageRow] {
        queue.sync {
            let cutoff = Self.dayFormat.string(from: Date().addingTimeInterval(-Double(days) * 86400))
            return rows.values.filter { $0.day >= cutoff }.sorted { ($0.day, $0.client, $0.model) < ($1.day, $1.client, $1.model) }
        }
    }

    func clear() {
        queue.async { self.rows = [:]; self.dirty = true; self.flush(); DispatchQueue.main.async { self.onChange?() } }
    }

    func flush() {
        queue.async {
            guard self.dirty else { return }
            self.dirty = false
            try? FileManager.default.createDirectory(at: AppConfig.directory, withIntermediateDirectories: true)
            if let data = try? JSONEncoder().encode(Array(self.rows.values)) {
                try? data.write(to: Self.url, options: .atomic)
            }
        }
    }

    /// Pull token counts out of a reply. Works for OpenAI ("prompt_tokens"/"completion_tokens",
    /// incl. streamed usage chunks) and Anthropic ("input_tokens"/"output_tokens", incl.
    /// message_start + message_delta events). `text` is the start + end of the reply body.
    /// Prompt tokens served from the engine's cache, as its usage block reports them.
    static func cachedTokens(in text: String) -> Int {
        max(maxValue("cached_tokens", in: text), maxValue("cache_read_input_tokens", in: text))
    }

    private static func maxValue(_ key: String, in text: String) -> Int {
        var best = 0
        var search = text[...]
        while let r = search.range(of: "\"\(key)\":") {
            let rest = search[r.upperBound...].drop { $0 == " " }
            best = max(best, Int(rest.prefix { $0.isNumber }) ?? 0)
            search = search[r.upperBound...]
        }
        return best
    }

    static func tokens(in text: String) -> (input: Int, output: Int) {
        func maxValue(_ key: String) -> Int {
            var best = 0
            var search = text[...]
            while let r = search.range(of: "\"\(key)\":") {
                let rest = search[r.upperBound...].drop { $0 == " " }
                // Capped: the numbers come from reply text, and a sum of huge ones must not overflow.
                let digits = rest.prefix { $0.isNumber }.prefix(15)
                best = max(best, min(Int(digits) ?? 0, 1 << 40))
                search = search[r.upperBound...]
            }
            return best
        }
        // OpenAI's prompt_tokens includes cached tokens; Anthropic's input_tokens counts only the new
        // ones, with cache reads and writes reported beside it. Either way: the whole prompt.
        let anthropic = maxValue("input_tokens") + maxValue("cache_read_input_tokens") + maxValue("cache_creation_input_tokens")
        let input = max(maxValue("prompt_tokens"), anthropic)
        let output = max(maxValue("completion_tokens"), maxValue("output_tokens"))
        return (input, output)
    }
}
