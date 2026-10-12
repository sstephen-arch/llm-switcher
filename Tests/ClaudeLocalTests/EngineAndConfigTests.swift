import XCTest
@testable import LLM_Switcher

final class EngineAndConfigTests: XCTestCase {
    func testModelNamesMapToEnginesAndBack() {
        XCTAssertEqual(Engines.kind(of: "Qwen3.8-27B-8bit"), .omlx)
        XCTAssertEqual(Engines.kind(of: "splash/Qwen3.8-27B-8bit"), .splash)
        XCTAssertEqual(Engines.kind(of: "ollama/qwen3:8b"), .ollama)
        XCTAssertEqual(Engines.kind(of: "lmstudio/qwen/qwen3-8b"), .lmstudio)
        XCTAssertEqual(Engines.kind(of: "llamacpp/unsloth/Qwen3-8B-GGUF:Q4_K_M"), .llamacpp)
        XCTAssertEqual(Endpoint(engine: .ollama, upstream: "", key: "").upstreamName("ollama/qwen3:8b"), "qwen3:8b")
        XCTAssertEqual(Endpoint(engine: .lmstudio, upstream: "", key: "").upstreamName("lmstudio/qwen/qwen3-8b"), "qwen/qwen3-8b")
        XCTAssertEqual(Endpoint(engine: .splash, upstream: "", key: "").upstreamName("splash/X"), "splash/X",
                       "Splash serves the alias itself")
        XCTAssertEqual(Endpoint(engine: .omlx, upstream: "", key: "").upstreamName("Tiel"), "Tiel")
    }

    func testFreshConfigHasEveryExternalEngineWithAKey() throws {
        let cfg = AppConfig()
        for k in EngineKind.external {
            let s = cfg.engine(k)
            XCTAssertFalse(s.enabled)
            XCTAssertEqual(s.port, k.defaultPort)
            XCTAssertTrue(s.key.hasPrefix("sk-"))
        }
        let back = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(back.engine(.llamacpp).key, cfg.engine(.llamacpp).key, "keys survive a save/load")
        XCTAssertEqual(Set(EngineKind.allCases.map(\.defaultPort)).count, EngineKind.allCases.count, "default ports never clash")
    }

    func testLockIgnoresWhatTheAppSends() {
        var p = ModelPreset()
        p.lockSampling = true
        p.temperature = 1.0
        var payload: [String: Any] = ["model": "m", "temperature": 0.2, "top_k": 5, "repeat_penalty": 1.3]
        Presets.apply(p, to: &payload, path: "/v1/chat/completions")
        XCTAssertEqual(payload["temperature"] as? Double, 1.0)
        XCTAssertNil(payload["top_k"])
        XCTAssertNil(payload["repeat_penalty"])
        var unlocked: [String: Any] = ["temperature": 0.2]
        Presets.apply(ModelPreset(), to: &unlocked, path: "/v1/chat/completions")
        XCTAssertEqual(unlocked["temperature"] as? Double, 0.2)
    }

    func testCleanNameDropsQuantAndPackaging() {
        XCTAssertEqual(BestConfig.cleanName("Qwen3.8-27B-8bit"), "Qwen3.8-27B")
        XCTAssertEqual(BestConfig.cleanName("Qwen3.8-Flash-Next-oQ4e-mtp"), "Qwen3.8-Flash-Next")
        XCTAssertEqual(BestConfig.cleanName("Tiel-Coder-35B-A3B-MLX-oQ6e-MTP"), "Tiel-Coder-35B-A3B")
        XCTAssertEqual(BestConfig.cleanName("Qwen3-8B-GGUF"), "Qwen3-8B")
        XCTAssertEqual(BestConfig.cleanName("Qwen3-8B-Q4_K_M"), "Qwen3-8B")
        XCTAssertEqual(BestConfig.unslothRepos(base: "Qwen/Qwen3-8B", repo: "mlx-community/Qwen3-8B-8bit"), ["unsloth/Qwen3-8B-GGUF"])
    }

    func testRecommendationParsing() {
        let gc: [String: Any] = ["temperature": 0.6, "top_p": 0.95, "top_k": 20, "do_sample": true]
        let r = BestConfig.recommendation(from: gc, source: "s", url: "u")
        XCTAssertEqual(r?.temperature, 0.6)
        XCTAssertEqual(r?.topK, 20)
        XCTAssertEqual(r?.summary, "temp 0.6 · top-p 0.95 · top-k 20")
        let unsloth: [String: Any] = ["temperature": 1, "min_p": 0, "repeat_penalty": 1, "top_k": 20]
        XCTAssertEqual(BestConfig.recommendation(from: unsloth, source: "s", url: "u")?.repetitionPenalty, 1)
        XCTAssertNil(BestConfig.recommendation(from: ["do_sample": false], source: "s", url: "u"), "greedy-only isn't advice")
    }

    func testBaseModelFromModelCard() {
        XCTAssertEqual(BestConfig.parseBaseModel("---\nlicense: mit\nbase_model: Qwen/Qwen3.8-27B\n---\n"), "Qwen/Qwen3.8-27B")
        XCTAssertEqual(BestConfig.parseBaseModel("---\nbase_model:\n- Qwen/Qwen3.6-35B-A3B\ntags: [mlx]\n---"), "Qwen/Qwen3.6-35B-A3B")
        XCTAssertNil(BestConfig.parseBaseModel("# Just a readme"))
    }

    func testTemplateThinkingLevels() {
        let t = BestConfig.parseTemplate("""
        {%- set reasoning_effort = reasoning_effort | default('xhigh') %}{% if reasoning_effort in ['low', 'medium', 'xhigh'] %}{% endif %}{% if enable_thinking %}{% endif %}
        """)
        XCTAssertTrue(t.thinkingSwitch)
        XCTAssertEqual(t.effortLevels, ["low", "medium", "xhigh"])
        XCTAssertEqual(t.defaultEffort, "xhigh")
        XCTAssertFalse(BestConfig.parseTemplate("{{ messages }}").thinkingSwitch)
    }

    func testCallerDisablingThinkingIsRecognised() {
        XCTAssertTrue(Presets.callerDisabledThinking(["thinking": ["type": "disabled"]]))
        XCTAssertTrue(Presets.callerDisabledThinking(["reasoning_effort": "none"]))
        XCTAssertTrue(Presets.callerDisabledThinking(["reasoning": ["effort": "none"]]))
        XCTAssertFalse(Presets.callerDisabledThinking(["thinking": ["type": "enabled", "budget_tokens": 1024]]))
        XCTAssertFalse(Presets.callerDisabledThinking([:]))
    }
}
