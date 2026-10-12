import XCTest
@testable import LLM_Switcher

final class SandboxTests: XCTestCase {
    func testSandboxBlocksHomeReadsAndOtherPrograms() {
        let secret = NSHomeDirectory() + "/Library/Application Support/ClaudeLocal/config.json"
        XCTAssertTrue(Benchmark.runTests(code: "open(\"\(secret)\").read()", tests: "").hasPrefix("FAIL"))
        XCTAssertTrue(Benchmark.runTests(code: "import subprocess\nsubprocess.run(['/bin/echo', 'x'])", tests: "").hasPrefix("FAIL"))
        XCTAssertEqual(Benchmark.runTests(code: "print('x' * 200000)", tests: ""), "PASS", "big output mustn't stall")
        XCTAssertEqual(Benchmark.runTests(code: "import json, heapq, collections, re", tests: ""), "PASS")
    }

    func testOldRequestLogLinesStillLoad() throws {
        let old = #"{"id":"9C8B3D52-9C4B-4C9D-9D4E-1F0B8E0C1A11","date":"2026-10-12T01:00:00Z","client":"c","address":"a","model":"m","path":"/v1/messages","status":200,"inputTokens":5,"outputTokens":6,"seconds":1.5}"#
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let a = try dec.decode(Gateway.Activity.self, from: Data(old.utf8))
        XCTAssertEqual(a.outputTokens, 6)
        XCTAssertEqual(a.engine, "")
        XCTAssertNil(a.firstWord)
    }
}
