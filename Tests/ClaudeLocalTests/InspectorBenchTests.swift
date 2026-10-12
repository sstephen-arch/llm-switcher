import XCTest
@testable import LLM_Switcher

final class InspectorBenchTests: XCTestCase {
    func testLastPythonBlockIsTheAnswer() {
        let text = "Plan:\n```python\nx = 1\n```\nFinal:\n```python\ndef f():\n    return 2\n```\nDone."
        XCTAssertEqual(Benchmark.lastPythonBlock(text), "def f():\n    return 2\n")
        XCTAssertEqual(Benchmark.lastPythonBlock("```\nprint(1)\n```"), "print(1)\n")
    }

    func testSandboxGradesPassFailTimeoutAndBlocksWrites() {
        XCTAssertEqual(Benchmark.runTests(code: "def add(a, b):\n    return a + b", tests: "assert add(2, 3) == 5"), "PASS")
        XCTAssertTrue(Benchmark.runTests(code: "def add(a, b):\n    return a - b", tests: "assert add(2, 3) == 5").hasPrefix("FAIL"))
        XCTAssertEqual(Benchmark.runTests(code: "while True: pass", tests: ""), "FAIL (took over 30 s)")
        let marker = "/tmp/llm-switcher-sandbox-test-\(UUID().uuidString)"
        let r = Benchmark.runTests(code: "open('\(marker)', 'w').write('x')", tests: "")
        XCTAssertTrue(r.hasPrefix("FAIL"), r)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "the sandbox must stop writes outside its folder")
    }

    func testTwelveCodingTasksShip() {
        let tasks = Benchmark.tasks()
        XCTAssertEqual(tasks.count, 12)
        XCTAssertEqual(tasks.filter { $0.set == "hard" }.count, 6)
        XCTAssertTrue(tasks.allSatisfy { !$0.tests.isEmpty && !$0.prompt.isEmpty })
    }

    func testRecallPromptHidesTheWordOnce() {
        let (prompt, word) = Benchmark.recallPrompt()
        XCTAssertEqual(prompt.components(separatedBy: word).count, 2)
        XCTAssertGreaterThan(prompt.count, 30_000, "about 8k tokens")
    }

    func testRequestSpeedsAndCacheParsing() {
        var a = Gateway.Activity(date: Date(), client: "c", address: "a", model: "m", path: "/v1/messages",
                                 status: 200, inputTokens: 10_000, outputTokens: 500, seconds: 15)
        a.stream = true; a.cachedTokens = 8_000; a.firstWord = 5
        XCTAssertEqual(a.readSpeed, 400)          // 2,000 uncached tokens in 5 s
        XCTAssertEqual(a.writeSpeed, 50)          // 500 tokens in the 10 s after the first word
        a.stream = false
        XCTAssertNil(a.writeSpeed)
        XCTAssertEqual(UsageStore.cachedTokens(in: #"{"usage":{"prompt_tokens_details":{"cached_tokens":1234}}}"#), 1234)
        XCTAssertEqual(UsageStore.cachedTokens(in: #"{"usage":{"cache_read_input_tokens":77,"input_tokens":5}}"#), 77)
    }

    func testFirstOutputDetection() {
        XCTAssertFalse(StreamRelay.hasOutput(Data(#"data: {"choices":[{"delta":{"role":"assistant","content":""}}]}"#.utf8)))
        XCTAssertTrue(StreamRelay.hasOutput(Data(#"data: {"choices":[{"delta":{"content":"Hi"}}]}"#.utf8)))
        XCTAssertTrue(StreamRelay.hasOutput(Data(#"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"hm"}}"#.utf8)))
        XCTAssertFalse(StreamRelay.hasOutput(Data("event: ping\ndata: {\"type\": \"ping\"}\n\n".utf8)))
    }
}
