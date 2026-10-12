import Foundation

/// Draft fast, then adversarial review and fix rounds, keeping the best version. Measured on a
/// five-problem bench (10 Oct 2026): a fast writer with thinking off plus a different reviewer
/// solved problems a single model reviewing itself could not, and "keep the best version" stopped
/// a late fix from throwing away a working one.
@MainActor
final class ReviewLoop: ObservableObject {
    struct Step: Identifiable {
        let id = UUID()
        let title: String
        var detail: String
        var seconds: Double = 0
        var tokens: Int = 0
        var ok: Bool? = nil
    }

    struct Settings {
        var task: String
        var writer: String
        var reviewer: String
        var rounds: Int
        var reviewerEffort: String  // "low", "medium" or "high"
        var folder: String          // empty = no tests
        var fileName: String
        var testCommand: String
    }

    @Published var steps: [Step] = []
    @Published var running = false
    @Published var finalCode = ""
    @Published var summary = ""

    private var job: Task<Void, Never>?

    func start(_ s: Settings) {
        guard !running else { return }
        steps = []; finalCode = ""; summary = ""
        running = true
        job = Task { await run(s); running = false }
    }

    func cancel() {
        job?.cancel()
        summary = "Stopped."
        running = false
    }

    private func run(_ s: Settings) async {
        let tests = !s.folder.isEmpty && !s.testCommand.trimmingCharacters(in: .whitespaces).isEmpty && !s.fileName.isEmpty
        let t0 = Date()
        guard let draft = await ask("Draft", s.writer, Self.draftPrompt(s.task), effort: "none"),
              var code = Self.extractCode(draft) else {
            summary = "The writer didn't return any code."
            return
        }
        var best = (code: code, score: -1.0, round: 0)
        var reviewedClean = false
        for round in 0...s.rounds {
            if Task.isCancelled { return }
            var failures = ""
            var passed = false
            if tests {
                let r = await runTests(code, s)
                passed = r.passed
                failures = passed ? "" : "Running `\(s.testCommand)` failed:\n\(r.output)"
                steps.append(Step(title: "Tests, round \(round)", detail: r.summary, seconds: r.seconds, ok: passed))
                if r.score > best.score || (r.score == best.score && passed) { best = (code, r.score, round) }
            } else {
                best = (code, 0, round)
            }
            if round == s.rounds || (passed && reviewedClean) { break }
            if tests && passed {
                // Passing tests aren't proof: one adversarial review hunts for what they missed.
                guard let review = await ask("Adversarial review", s.reviewer, Self.reviewPrompt(s.task, code, ""), effort: s.reviewerEffort) else { break }
                if review.uppercased().contains("NO ISSUES") && review.count < 400 { break }
                reviewedClean = true
                guard let fixed = await ask("Fix", s.writer, Self.fixPrompt(s.task, code, "", review), effort: "none"),
                      let newCode = Self.extractCode(fixed) else { break }
                code = newCode
                continue
            }
            guard let review = await ask("Review", s.reviewer, Self.reviewPrompt(s.task, code, failures), effort: s.reviewerEffort) else { break }
            if !tests && review.uppercased().contains("NO ISSUES") && review.count < 400 { break }
            guard let fixed = await ask("Fix", s.writer, Self.fixPrompt(s.task, code, failures, review), effort: "none"),
                  let newCode = Self.extractCode(fixed) else { break }
            code = newCode
            if !tests { best = (code, 0, round + 1) }
        }
        if Task.isCancelled { return }
        finalCode = best.code
        if tests {
            try? best.code.write(to: URL(fileURLWithPath: s.folder).appendingPathComponent(s.fileName), atomically: true, encoding: .utf8)
        }
        let mins = Date().timeIntervalSince(t0) / 60
        if tests {
            let verdict = best.score >= 1 ? "tests pass" : String(format: "best version passed %.0f%% of tests", max(0, best.score) * 100)
            summary = String(format: "Done in %.1f min: kept the version from round %d (%@). It's saved to %@.", mins, best.round, verdict, s.fileName)
        } else {
            summary = String(format: "Done in %.1f min. No tests were set, so this is the reviewed version from round %d.", mins, best.round)
        }
    }

    // MARK: model calls

    private func ask(_ title: String, _ model: String, _ prompt: String, effort: String) async -> String? {
        steps.append(Step(title: title, detail: "\(model) working…"))
        let i = steps.count - 1
        let started = Date()
        // The model may run in oMLX or Splash; ask the engine that serves it.
        let cfg = AppConfig.load()
        let endpoint = await Engines.endpoint(for: model, cfg)
        guard var req = endpoint.request("/v1/chat/completions", timeout: 1800) else { return nil }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            // "high" can think for 20,000+ tokens before writing the review; a smaller allowance
            // returns an empty one (measured on gpt-oss-120b, 10 Oct 2026). No temperature: each
            // model's tuned sampling lives in oMLX's per-model settings, and a low one makes
            // thinking models loop (Flash-Next and Tiel did, 11 Oct 2026).
            "model": model, "max_tokens": effort == "high" ? 32000 : 16000, "reasoning_effort": effort,
            "messages": [["role": "system", "content": "You are an expert programmer."], ["role": "user", "content": prompt]]]
        if effort == "none" { Presets.disableThinking(&body) }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let work = Task { try await URLSession.shared.data(for: req) }
        // oMLX drops requests when it reloads or restarts and never answers: same check as the gateway.
        let monitor = Task {
            var idle = 0
            while !Task.isCancelled && idle < 3 {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                idle = await endpoint.looksIdle() ? idle + 1 : 0
            }
            if idle >= 3 { work.cancel() }
        }
        defer { monitor.cancel() }
        do {
            let (data, resp) = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let text = ((obj?["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String ?? ""
            let tokens = (obj?["usage"] as? [String: Any])?["completion_tokens"] as? Int ?? 0
            let secs = Date().timeIntervalSince(started)
            UsageStore.shared.record(client: "Review loop", model: model, status: code,
                                     input: (obj?["usage"] as? [String: Any])?["prompt_tokens"] as? Int ?? 0, output: tokens, seconds: secs)
            guard code == 200, !text.isEmpty else {
                steps[i].detail = "\(model) failed (\(code))"; steps[i].ok = false
                return nil
            }
            steps[i].detail = "\(model) · " + Self.preview(text)
            steps[i].seconds = secs
            steps[i].tokens = tokens
            steps[i].ok = true
            return text
        } catch {
            steps[i].detail = Task.isCancelled ? "Stopped"
                : (work.isCancelled ? "oMLX dropped this request (reloaded or restarted)" : "\(model) failed: \(error.localizedDescription)")
            steps[i].ok = false
            return nil
        }
    }

    private static func preview(_ text: String) -> String {
        let firstLine = text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !$0.hasPrefix("```") } ?? ""
        return String(firstLine.prefix(140))
    }

    // MARK: tests

    private struct TestResult { let passed: Bool; let score: Double; let output: String; let summary: String; let seconds: Double }

    /// Writes the code to the chosen file and runs the test command in that folder (login shell,
    /// 5-minute limit). Exit code 0 means pass; "N passed, M failed" in the output gives a score.
    private func runTests(_ code: String, _ s: Settings) async -> TestResult {
        let folder = URL(fileURLWithPath: s.folder)
        do {
            try code.write(to: folder.appendingPathComponent(s.fileName), atomically: true, encoding: .utf8)
        } catch {
            return TestResult(passed: false, score: -1, output: "", summary: "Couldn't save \(s.fileName): \(error.localizedDescription)", seconds: 0)
        }
        let started = Date()
        let (status, out) = await Task.detached { () -> (Int32, String) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", s.testCommand]
            p.currentDirectoryURL = folder
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            let lock = NSLock()
            var data = Data()
            pipe.fileHandleForReading.readabilityHandler = { h in
                let chunk = h.availableData
                lock.lock(); if data.count < 4_000_000 { data.append(chunk) }; lock.unlock()
            }
            do { try p.run() } catch { return (127, "Couldn't run the command: \(error.localizedDescription)") }
            let deadline = Date().addingTimeInterval(300)
            while p.isRunning && Date() < deadline { usleep(200_000) }
            var timedOut = false
            if p.isRunning {
                timedOut = true
                // The shell's children (test runners) can outlive it: stop the whole tree.
                let pk = Process()
                pk.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                pk.arguments = ["-TERM", "-P", String(p.processIdentifier)]
                try? pk.run(); pk.waitUntilExit()
                p.terminate()
                usleep(500_000)
                if p.isRunning { kill(p.processIdentifier, SIGKILL) }
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            lock.lock(); let text = String(decoding: data, as: UTF8.self); lock.unlock()
            return (timedOut ? 124 : p.terminationStatus, timedOut ? text + "\n[stopped after 5 minutes]" : text)
        }.value
        let tail = String(out.suffix(4000))
        let passed = status == 0
        var score = passed ? 1.0 : 0.0
        var summary = passed ? "Passed" : "Failed (exit \(status))"
        func count(_ word: String) -> Int? {
            guard let r = out.range(of: #"(\d+) \#(word)"#, options: [.regularExpression, .backwards]) else { return nil }
            return Int(out[r].split(separator: " ").first ?? "")
        }
        if let p = count("passed") {
            let f = (count("failed") ?? 0) + (count("error") ?? 0)
            if p + f > 0 { score = passed ? 1.0 : Double(p) / Double(p + f) }
            summary = "\(p) passed" + (f > 0 ? ", \(f) failed" : "")
        }
        return TestResult(passed: passed, score: score, output: tail, summary: summary, seconds: Date().timeIntervalSince(started))
    }

    // MARK: prompts

    static func extractCode(_ text: String) -> String? {
        let pattern = #"```[A-Za-z0-9_+-]*\s*\n(.*?)```"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = text as NSString
        let blocks = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
        return blocks.max(by: { $0.count < $1.count }) ?? (text.contains("\n") ? text : nil)
    }

    static func draftPrompt(_ task: String) -> String {
        "\(task)\n\nWrite the complete solution in a single code block. Work quickly: a solid first draft is the goal, it will be reviewed."
    }

    static func reviewPrompt(_ task: String, _ code: String, _ failures: String) -> String {
        let tests = failures.isEmpty ? "Any automated tests currently pass, but they are not exhaustive." : failures
        return """
        Review this code adversarially against the task. Hunt for bugs, unmet requirements, unhandled edge cases \
        and performance problems.

        TASK:
        \(task)

        CODE:
        ```
        \(code)
        ```

        \(tests)

        For each problem give: what is wrong, a concrete input that triggers it, and how to fix it. Be specific \
        and concise. Do not rewrite the whole program. If you find nothing wrong, reply exactly: NO ISSUES
        """
    }

    static func fixPrompt(_ task: String, _ code: String, _ failures: String, _ review: String) -> String {
        """
        TASK:
        \(task)

        YOUR CURRENT CODE:
        ```
        \(code)
        ```

        \(failures.isEmpty ? "" : failures + "\n\n")A REVIEWER REPORTED:
        \(review)

        Fix every real problem (the reviewer can be wrong; failing tests are ground truth). Return the complete \
        corrected solution in a single code block.
        """
    }
}
