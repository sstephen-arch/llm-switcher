import XCTest
@testable import LLM_Switcher

/// The gateway watchdog ends requests oMLX has dropped. These cases pin what counts as progress.
final class WatchdogTests: XCTestCase {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    func testAnthropicPingIsNotProgress() {
        XCTAssertTrue(StreamRelay.isPing(data("event: ping\ndata: {\"type\": \"ping\"}\n\n")))
    }

    func testCommentKeepAliveIsNotProgress() {
        XCTAssertTrue(StreamRelay.isPing(data(": keep-alive\n\n")))
    }

    func testTextDeltaIsProgress() {
        XCTAssertFalse(StreamRelay.isPing(data("event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"Hi\"}}\n\n")))
    }

    func testOpenAIChunkIsProgress() {
        XCTAssertFalse(StreamRelay.isPing(data("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n")))
    }

    func testPingMixedWithOutputIsProgress() {
        XCTAssertFalse(StreamRelay.isPing(data("event: ping\ndata: {\"type\": \"ping\"}\n\nevent: content_block_delta\ndata: {\"delta\":{\"text\":\"a\"}}\n\n")))
    }

    func testAbortNeedsThreeIdleChecksAndSilence() {
        XCTAssertFalse(StreamRelay.shouldAbort(idleChecks: 2, quietFor: 300))   // could be a model still loading
        XCTAssertFalse(StreamRelay.shouldAbort(idleChecks: 3, quietFor: 30))    // output arrived recently
        XCTAssertTrue(StreamRelay.shouldAbort(idleChecks: 3, quietFor: 61))
    }

    func testFitClassification() {
        let gb: Int64 = 1_073_741_824
        XCTAssertEqual(ModelCheck.classify(size: 60 * gb, ceiling: 107 * gb, ram: 128 * gb), .fits)
        XCTAssertEqual(ModelCheck.classify(size: 100 * gb, ceiling: 107 * gb, ram: 128 * gb), .tight)
        XCTAssertEqual(ModelCheck.classify(size: 110 * gb, ceiling: 107 * gb, ram: 128 * gb), .needsLimitRaised)
        XCTAssertEqual(ModelCheck.classify(size: 150 * gb, ceiling: 107 * gb, ram: 128 * gb), .tooBig)
    }
}

/// "Thinking off" must reach the chat template, or oMLX turns "none" into "low" for some models.
final class PresetTests: XCTestCase {
    func testThinkingOffSetsTemplateSwitchAndKeepsCallerKwargs() {
        var p = ModelPreset(); p.thinking = "off"
        var payload: [String: Any] = ["model": "m", "max_tokens": 100, "chat_template_kwargs": ["foo": 1]]
        Presets.apply(p, to: &payload, path: "/v1/chat/completions")
        let kw = payload["chat_template_kwargs"] as? [String: Any]
        XCTAssertEqual(kw?["enable_thinking"] as? Bool, false)
        XCTAssertEqual(kw?["foo"] as? Int, 1)
        XCTAssertEqual(payload["reasoning_effort"] as? String, "none")
    }

    func testDefaultThinkingLeavesRequestAlone() {
        var payload: [String: Any] = ["model": "m", "max_tokens": 100]
        Presets.apply(ModelPreset(), to: &payload, path: "/v1/messages")
        XCTAssertNil(payload["chat_template_kwargs"])
    }
}
