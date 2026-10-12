import Foundation

/// One-click benchmark for any model on any engine, through LLM Switcher's own gateway (so each
/// model's tuned settings apply, as they do for Claude). Never sends a temperature.
///
/// - Speed: first word, writing speed, reading speed on a ~8k-token prompt (with a recall check),
///   four requests at once.
/// - Tools: one tool call, checked.
/// - Coding: the model-bench problems (6 hard + 6 harder), each graded by hidden tests run in a
///   macOS sandbox (no network, no writes outside a temporary folder).
struct BenchResult: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    var model: String
    var engine: String
    var thinking: String
    var firstWord: Double?
    var writeSpeed: Double?
    var readSpeed: Double?
    var readRecall: Bool?
    var parallelSpeed: Double?
    var toolCall: Bool?
    var codingPassed: Int?
    var codingTotal: Int?
    var codingDetails: [String: String] = [:]
    var minutes: Double = 0
}

struct BenchTask: Codable {
    let set: String
    let name: String
    let prompt: String
    let tests: String
}

@MainActor
final class Benchmark: ObservableObject {
    struct Options: Equatable {
        var speed = true
        var tools = true
        /// "none", "hard" (6 problems) or "all" (12).
        var coding = "hard"
        /// "default", "off", "low", "medium", "high" (coding only; speed always runs with thinking off).
        var thinking = "default"
    }

    @Published private(set) var running = false
    @Published private(set) var steps: [String] = []
    @Published private(set) var results: [BenchResult] = []
    private var job: Task<Void, Never>?
    /// What the latest run produced (nil while running or when it failed).
    private var lastResult: BenchResult?

    static let folder = AppConfig.directory.appendingPathComponent("bench", isDirectory: true)

    init() { results = Self.loadResults() }

    nonisolated static func tasks() -> [BenchTask] {
        guard let url = Bundle.main.url(forResource: "coding-tasks", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["tasks"],
              let json = try? JSONSerialization.data(withJSONObject: list) else { return [] }
        return (try? JSONDecoder().decode([BenchTask].self, from: json)) ?? []
    }

    func start(model: String, options: Options, gateway port: Int) {
        guard !running else { return }
        running = true
        steps = []
        lastResult = nil
        job = Task {
            let r = await run(model: model, options: options, base: "http://127.0.0.1:\(port)")
            if let r { save(r) }
            lastResult = r
            running = false
        }
    }

    /// For `lsw bench`: runs and waits; nil when it failed or another run is going.
    func runAndWait(model: String, options: Options, gateway port: Int) async -> BenchResult? {
        guard !running else { return nil }
        start(model: model, options: options, gateway: port)
        await job?.value
        return lastResult
    }

    func stop() { job?.cancel(); log("Stopped.") }

    func delete(_ r: BenchResult) {
        try? FileManager.default.removeItem(at: Self.folder.appendingPathComponent("\(r.id.uuidString).json"))
        results.removeAll { $0.id == r.id }
    }

    private func log(_ s: String) { steps.append(s) }

    // MARK: running

    private func run(model: String, options o: Options, base: String) async -> BenchResult? {
        let started = Date()
        var r = BenchResult(model: model, engine: Engines.kind(of: model).label, thinking: o.thinking)
        log("Benchmarking \(model). Anything else using this model now will slow both down.")

        // Warm-up: loads the model (and starts its engine) so load time isn't counted as speed.
        log("Loading the model…")
        guard await Self.stream(base, model, [["role": "user", "content": "Say ok."]], maxTokens: 8) != nil else {
            log("❌ The model didn't answer. Is its engine installed and switched on?"); return nil
        }
        if Task.isCancelled { return nil }

        if o.speed {
            log("Writing speed…")
            if let s = await Self.stream(base, model, [["role": "user", "content": "Explain how a hash map works, in about 400 words."]], maxTokens: 600) {
                r.firstWord = s.firstWord
                r.writeSpeed = s.writeSpeed
                log("  first word \(f(s.firstWord))s · \(f(s.writeSpeed, 0)) tokens/s")
            }
            if Task.isCancelled { return nil }
            log("Reading speed (long prompt, ~10-15k tokens)…")
            let (prompt, answer) = Self.recallPrompt()
            if let s = await Self.stream(base, model, [["role": "user", "content": prompt]], maxTokens: 30) {
                r.readSpeed = s.firstWord > 0 && s.promptTokens > 0 ? Double(s.promptTokens) / s.firstWord : nil
                r.readRecall = s.text.contains(answer)
                log("  \(s.promptTokens) tokens read in \(f(s.firstWord))s · \(f(r.readSpeed, 0)) tokens/s · recall \(r.readRecall == true ? "correct" : "wrong")")
            }
            if Task.isCancelled { return nil }
            log("Four at once…")
            let t0 = Date()
            let outs = await withTaskGroup(of: Int.self) { g -> Int in
                for i in 0..<4 {
                    g.addTask { await Self.stream(base, model, [["role": "user", "content": "Story \(i): write a short story about a robot, about 250 words."]], maxTokens: 300)?.outputTokens ?? 0 }
                }
                return await g.reduce(0, +)
            }
            r.parallelSpeed = Double(outs) / Date().timeIntervalSince(t0)
            log("  \(outs) tokens in total · \(f(r.parallelSpeed, 0)) tokens/s together")
        }
        if Task.isCancelled { return nil }

        if o.tools {
            log("Tool call…")
            r.toolCall = await toolCall(base, model)
            log("  \(r.toolCall == true ? "✓ called the tool correctly" : "✗ no correct tool call")")
        }

        if o.coding != "none" {
            let tasks = Self.tasks().filter { o.coding == "all" || $0.set == "hard" }
            var passed = 0
            for (i, t) in tasks.enumerated() {
                if Task.isCancelled { return nil }
                log("Coding \(i + 1)/\(tasks.count): \(t.name)…")
                let outcome = await coding(base, model, t, thinking: o.thinking)
                r.codingDetails[t.name] = outcome
                if outcome == "PASS" { passed += 1 }
                log("  \(outcome)")
            }
            r.codingPassed = passed
            r.codingTotal = tasks.count
        }
        r.minutes = Date().timeIntervalSince(started) / 60
        log("Done in \(f(r.minutes)) min.")
        return r
    }

    struct StreamStats { var firstWord: Double; var writeSpeed: Double?; var outputTokens: Int; var promptTokens: Int; var text: String }

    /// A streamed chat with thinking off (speed tests measure the model, not how long it thinks).
    nonisolated static func stream(_ base: String, _ model: String, _ messages: [[String: Any]], maxTokens: Int) async -> StreamStats? {
        guard let url = URL(string: base + "/v1/chat/completions") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 1800)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "stream": true, "max_tokens": maxTokens, "reasoning_effort": "none",
            "stream_options": ["include_usage": true], "messages": messages] as [String: Any])
        let t0 = Date()
        var first: Date?
        var chunks = 0, prompt = 0, completion = 0
        var text = ""
        guard let (bytes, resp) = try? await URLSession.shared.bytes(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        do {
            for try await line in bytes.lines where line.hasPrefix("data:") {
                let json = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard json != "[DONE]", let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { continue }
                if let delta = ((obj["choices"] as? [[String: Any]])?.first)?["delta"] as? [String: Any] {
                    let piece = (delta["content"] as? String ?? "") + (delta["reasoning_content"] as? String ?? "") + (delta["reasoning"] as? String ?? "")
                    if !piece.isEmpty {
                        if first == nil { first = Date() }
                        chunks += 1
                        text += delta["content"] as? String ?? ""
                    }
                }
                if let u = obj["usage"] as? [String: Any] {
                    prompt = u["prompt_tokens"] as? Int ?? prompt
                    completion = u["completion_tokens"] as? Int ?? completion
                }
            }
        } catch { return nil }
        let end = Date()
        guard let first else { return nil }
        let out = completion > 0 ? completion : chunks
        let writing = end.timeIntervalSince(first)
        return StreamStats(firstWord: first.timeIntervalSince(t0), writeSpeed: writing > 0.05 && out > 1 ? Double(out) / writing : nil,
                           outputTokens: out, promptTokens: prompt, text: text)
    }

    /// A long prompt (~10-15k tokens, by tokenizer) of numbered lines with one code word hidden in them; asks for the code word.
    nonisolated static func recallPrompt() -> (String, String) {
        let word = "kiwi-\(Int.random(in: 1000...9999))"
        let target = Int.random(in: 200...500)
        var lines: [String] = ["[\(UUID().uuidString)]"]     // fresh each run, so no prompt cache helps
        for i in 1...700 {
            lines.append(i == target ? "Line \(i): the code word is \(word)."
                                     : "Line \(i): the weather report says light wind and clear skies over hill \(i * 7 % 97).")
        }
        lines.append("\nWhat is the code word? Reply with only the code word.")
        return (lines.joined(separator: "\n"), word)
    }

    private func toolCall(_ base: String, _ model: String) async -> Bool {
        guard let url = URL(string: base + "/v1/chat/completions") else { return false }
        var req = URLRequest(url: url, timeoutInterval: 600)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "max_tokens": 800, "reasoning_effort": "none",
            "tools": [["type": "function", "function": [
                "name": "read_file", "description": "Read a file from disk",
                "parameters": ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]]]]],
            "messages": [["role": "user", "content": "Open the file /etc/hosts using your tool."]]] as [String: Any])
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = ((obj["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any],
              let call = (msg["tool_calls"] as? [[String: Any]])?.first,
              let fn = call["function"] as? [String: Any] else { return false }
        return fn["name"] as? String == "read_file" && (fn["arguments"] as? String ?? "").contains("/etc/hosts")
    }

    private func coding(_ base: String, _ model: String, _ t: BenchTask, thinking: String) async -> String {
        guard let url = URL(string: base + "/v1/chat/completions") else { return "ERROR" }
        var req = URLRequest(url: url, timeoutInterval: 3600)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Room to think before the answer: thinking off needs little, a model's own default can be long.
        let limit = ["off": 6000, "low": 16000, "medium": 32000][thinking] ?? 64000
        var body: [String: Any] = ["model": model, "max_tokens": limit,
                                   "messages": [["role": "user", "content": t.prompt + " Reply with only the code in one ```python block."]]]
        if thinking != "default" { body["reasoning_effort"] = thinking == "off" ? "none" : thinking }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return "ERROR no answer" }
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = ((obj["choices"] as? [[String: Any]])?.first)?["message"] as? [String: Any] else {
            return "ERROR \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
        }
        let answer = msg["content"] as? String ?? ""
        let code = Self.lastPythonBlock(answer)
        if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "FAIL (empty answer; ran out of room while thinking?)" }
        return await Task.detached { Self.runTests(code: code, tests: t.tests) }.value
    }

    nonisolated static func lastPythonBlock(_ text: String) -> String {
        let parts = text.components(separatedBy: "```")
        // Odd-numbered pieces are inside fences; take the last one, minus its language tag.
        let blocks = stride(from: 1, to: parts.count, by: 2).map { parts[$0] }
        guard var b = blocks.last else { return text }
        if let nl = b.firstIndex(of: "\n"), b[..<nl].allSatisfy({ $0.isLetter }) { b = String(b[b.index(after: nl)...]) }
        return b
    }

    nonisolated static var python: String? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Runs the model's code plus the hidden tests in a sandbox: no network, no reading the home
    /// folder (keys, SSH, this app's settings), no writing outside its own temporary folder, no
    /// other programs, and 30 seconds at most. Output goes to files, so a chatty answer can't
    /// stall on a full pipe.
    nonisolated static func runTests(code: String, tests: String) -> String {
        guard let python else { return "ERROR Python 3 isn't installed (brew install python)" }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("llm-switcher-bench-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let file = dir.appendingPathComponent("answer.py")
        try? (code + "\n\n" + tests + "\nprint('PASS')\n").write(to: file, atomically: true, encoding: .utf8)
        let real = dir.resolvingSymlinksInPath().path
        // Python may re-launch itself from inside its own install (Homebrew's framework build does).
        let resolved = URL(fileURLWithPath: python).resolvingSymlinksInPath().path
        let pyHome = resolved.range(of: "/Versions/").map { String(resolved[..<$0.lowerBound]) } ?? (resolved as NSString).deletingLastPathComponent
        let execOK = [pyHome, "/Library/Developer/CommandLineTools", "/Applications/Xcode.app"]
            .map { "(subpath \"\($0)\")" }.joined(separator: " ")
        let profile = """
        (version 1)(allow default)(deny network*)
        (deny file-write* (require-not (subpath "\(real)")))
        (allow file-write* (literal "/dev/null") (literal "/dev/dtracehelper"))
        (deny file-read* (subpath "\(NSHomeDirectory())"))
        (deny process-fork)
        (deny process-exec (require-not (require-any \(execOK))))
        """
        let outURL = dir.appendingPathComponent("out.txt"), errURL = dir.appendingPathComponent("err.txt")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: outURL), let err = try? FileHandle(forWritingTo: errURL) else {
            return "ERROR couldn't set up the test folder"
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", profile, python, "-I", "-B", file.path]
        p.currentDirectoryURL = dir
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return "ERROR couldn't run the tests" }
        let deadline = Date().addingTimeInterval(30)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        let timedOut = p.isRunning
        if timedOut { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit()
        try? out.close(); try? err.close()
        if timedOut { return "FAIL (took over 30 s)" }
        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        if stdout.contains("PASS") { return "PASS" }
        let last = stderr.split(separator: "\n").last.map(String.init) ?? (stdout.isEmpty ? "no output" : String(stdout.prefix(80)))
        return "FAIL " + String(last.prefix(100))
    }

    // MARK: results

    private func save(_ r: BenchResult) {
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(r) { try? data.write(to: Self.folder.appendingPathComponent("\(r.id.uuidString).json")) }
        results.insert(r, at: 0)
    }

    static func loadResults() -> [BenchResult] {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? dec.decode(BenchResult.self, from: Data(contentsOf: $0)) }
            .sorted { $0.date > $1.date }
    }

    private func f(_ v: Double?, _ digits: Int = 1) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "–" }
}
