import AppKit
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
        /// Run after the tests each round; it must save a PNG to $OUT (empty = no screenshots).
        /// The reviewer sees it, to catch what tests can't: clipped labels, missing text, layout.
        var screenshotCommand: String = ""
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
        job = Task {
            await run(s)
            if Task.isCancelled { summary = "Stopped." }
            running = false
        }
    }

    func cancel() {
        job?.cancel()
        summary = "Stopping…"
        // `running` goes false when the job ends: its test and screenshot commands are killed on
        // cancel, so a new run can't start beside a command that's still going.
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
                failures = passed ? "" : (r.output.isEmpty ? r.summary : "Running `\(s.testCommand)` failed:\n\(r.output)")
                steps.append(Step(title: "Tests, round \(round)", detail: r.summary, seconds: r.seconds, ok: passed))
                if r.score > best.score || (r.score == best.score && passed) { best = (code, r.score, round) }
            } else {
                best = (code, 0, round)
            }
            if round == s.rounds || (passed && reviewedClean) { break }
            let shot = s.screenshotCommand.trimmingCharacters(in: .whitespaces).isEmpty || s.folder.isEmpty
                ? nil : await screenshot(s, round: round)
            if tests && passed {
                // Passing tests aren't proof: one adversarial review hunts for what they missed.
                guard let review = await ask("Adversarial review", s.reviewer, Self.reviewPrompt(s.task, code, "", screenshot: shot != nil),
                                             effort: s.reviewerEffort, image: shot,
                                             textOnly: Self.reviewPrompt(s.task, code, "")) else { break }
                if review.uppercased().contains("NO ISSUES") && review.count < 400 { break }
                reviewedClean = true
                guard let fixed = await ask("Fix", s.writer, Self.fixPrompt(s.task, code, "", review), effort: "none"),
                      let newCode = Self.extractCode(fixed) else { break }
                code = newCode
                continue
            }
            let context = tests ? failures : "No automated tests are set up for this task; review the code on its own."
            guard let review = await ask("Review", s.reviewer, Self.reviewPrompt(s.task, code, context, screenshot: shot != nil),
                                         effort: s.reviewerEffort, image: shot,
                                         textOnly: Self.reviewPrompt(s.task, code, context)) else { break }
            if !tests && review.uppercased().contains("NO ISSUES") && review.count < 400 { break }
            guard let fixed = await ask("Fix", s.writer, Self.fixPrompt(s.task, code, failures, review), effort: "none"),
                  let newCode = Self.extractCode(fixed) else { break }
            code = newCode
            if !tests { best = (code, 0, round + 1) }
        }
        if Task.isCancelled { return }
        finalCode = best.code
        var saveError: String?
        if tests {
            do { try best.code.write(to: URL(fileURLWithPath: s.folder).appendingPathComponent(s.fileName), atomically: true, encoding: .utf8) }
            catch { saveError = error.localizedDescription }
        }
        let mins = Date().timeIntervalSince(t0) / 60
        if tests {
            let verdict = best.score >= 1 ? "tests pass" : String(format: "best version passed %.0f%% of tests", max(0, best.score) * 100)
            summary = String(format: "Done in %.1f min: kept the version from round %d (%@). ", mins, best.round, verdict)
                + (saveError.map { "Saving it to \(s.fileName) failed: \($0). Copy it from below." } ?? "It's saved to \(s.fileName).")
        } else {
            summary = String(format: "Done in %.1f min. No tests were set, so this is the reviewed version from round %d.", mins, best.round)
        }
    }

    // MARK: model calls

    /// `textOnly`: the prompt to use if the model refuses the image (it must not mention one).
    private func ask(_ title: String, _ model: String, _ prompt: String, effort: String,
                     image: Data? = nil, textOnly: String? = nil) async -> String? {
        steps.append(Step(title: title, detail: "\(model) working…"))
        let i = steps.count - 1
        guard let image else { return await call(i, model, prompt, effort: effort, image: nil) }
        if let text = await call(i, model, prompt, effort: effort, image: image) { return text }
        guard !Task.isCancelled else { return nil }
        // A model that can't read images refuses the request: review without the screenshot.
        steps[i].detail = "\(model) couldn't take the screenshot; reviewing without it…"
        steps[i].ok = nil
        let text = await call(i, model, textOnly ?? prompt, effort: effort, image: nil)
        if text != nil { steps[i].detail += " (reviewed without the screenshot)" }
        return text
    }

    private func call(_ i: Int, _ model: String, _ prompt: String, effort: String, image: Data?) async -> String? {
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
            "messages": [["role": "system", "content": "You are an expert programmer."], ["role": "user", "content": Self.userContent(prompt, image)]]]
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
            steps[i].detail = (image == nil && steps[i].detail.hasPrefix("\(model) couldn't take") ? "" : "\(model) · ") + Self.preview(text)
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

    /// The prompt, plus the screenshot as an image part (OpenAI chat format) when there is one.
    nonisolated static func userContent(_ prompt: String, _ image: Data?) -> Any {
        guard let image else { return prompt }
        return [["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64," + image.base64EncodedString()]]]
    }

    /// Runs the screenshot command in the folder with $OUT set to a PNG path; nil if no image came back.
    private func screenshot(_ s: Settings, round: Int) async -> Data? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("review-shot-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: out) }
        let started = Date()
        let (status, text) = await Self.shell(s.screenshotCommand, folder: URL(fileURLWithPath: s.folder),
                                              env: ["OUT": out.path], timeout: 120)
        let data = try? Data(contentsOf: out)
        let ok = status == 0 && (data.map { $0.count < 8_000_000 && $0.starts(with: [0x89, 0x50, 0x4E, 0x47])
            && NSImage(data: $0) != nil } ?? false)
        steps.append(Step(title: "Screenshot, round \(round)",
                          detail: ok ? "\(data!.count / 1024) KB, sent to the reviewer"
                                     : "No PNG at $OUT (exit \(status)): \(String(text.suffix(200)))",
                          seconds: Date().timeIntervalSince(started), ok: ok))
        return ok ? data : nil
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
        let (status, out) = await Self.shell(s.testCommand, folder: folder, timeout: 300)
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

    /// Runs a command in a login shell in `folder`; stops the whole tree after `timeout` seconds.
    nonisolated static func shell(_ command: String, folder: URL, env: [String: String] = [:], timeout: TimeInterval) async -> (Int32, String) {
        let p = Process()
        let stop = StopFlag()
        // Stop (the task cancelled) kills the command and everything it started, at once.
        return await withTaskCancellationHandler {
            await Task.detached { () -> (Int32, String) in
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            p.currentDirectoryURL = folder
            if !env.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 } }
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
            let deadline = Date().addingTimeInterval(timeout)
            while p.isRunning && Date() < deadline && !stop.isSet { usleep(200_000) }
            if stop.isSet && p.isRunning { stopTree(p) }       // Stop came before or during the run
            var timedOut = false
            if p.isRunning {
                timedOut = true
                stopTree(p)
            }
            p.waitUntilExit()
            // The handler may not have seen the last output yet: wait until it stops growing (at most
            // 2 s; a leftover child holding the pipe open must not hang us), then close.
            var last = -1
            for _ in 0..<20 {
                lock.lock(); let n = data.count; lock.unlock()
                if n == last { break }
                last = n
                usleep(100_000)
            }
            pipe.fileHandleForReading.readabilityHandler = nil
            lock.lock(); let text = String(decoding: data, as: UTF8.self); lock.unlock()
            return (timedOut ? 124 : p.terminationStatus, timedOut ? text + "\n[stopped after \(Int(timeout)) s]" : text)
            }.value
        } onCancel: {
            stop.set()
            if p.isRunning { stopTree(p) }
        }
    }

    /// Set from the cancel handler, read by the waiting loop (which may not have started the command yet).
    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// The shell's children and their children (swift test -> xctest, simulators) can outlive it:
    /// TERM the whole tree, then KILL whatever is left.
    nonisolated private static func stopTree(_ p: Process) {
        let tree = [p.processIdentifier] + descendants(of: p.processIdentifier)
        for pid in tree.reversed() { kill(pid, SIGTERM) }
        usleep(500_000)
        for pid in tree.reversed() where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    nonisolated private static func descendants(of root: pid_t) -> [pid_t] {
        var found: [pid_t] = [], queue = [root]
        while let pid = queue.popLast(), found.count < 500 {
            let pg = Process()
            pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            pg.arguments = ["-P", String(pid)]
            let out = Pipe(); pg.standardOutput = out; pg.standardError = FileHandle.nullDevice
            guard (try? pg.run()) != nil else { break }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            pg.waitUntilExit()
            let kids = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { pid_t($0) }
            found += kids; queue += kids
        }
        return found
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

    nonisolated static func reviewPrompt(_ task: String, _ code: String, _ failures: String, screenshot: Bool = false) -> String {
        var tests = failures.isEmpty ? "Any automated tests currently pass, but they are not exhaustive." : failures
        if screenshot {
            tests += "\n\nA screenshot of the running result is attached. Check it too: clipped or wrapped labels, missing " +
                "or unreadable text, broken layout, wrong colours, anything the tests can't see."
        }
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
