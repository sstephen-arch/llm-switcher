import XCTest
@testable import LLM_Switcher

final class EngineTests: XCTestCase {
    func testServedNameIsPrefixedRepoName() {
        XCTAssertEqual(SplashConfig.servedName("mlx-community/Qwen3.8-27B-8bit"), "splash/Qwen3.8-27B-8bit")
        XCTAssertEqual(SplashConfig.servedName("unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_M"), "splash/Qwen3.8-27B-GGUF")
    }

    func testServeArgumentsKeepKeyOutAndBindLoopback() {
        var c = SplashConfig()
        c.model = "mlx-community/Qwen3.8-27B-8bit"
        c.port = 8123
        c.maxContext = 131072
        c.reasoningEffort = "high"
        c.cacheDiskGB = 10
        c.persistentCache = true
        let a = Splash.serveArguments(c, offline: true)
        XCTAssertFalse(a.contains(c.key), "the key goes in the environment, never argv")
        XCTAssertEqual(a.first, "serve")
        XCTAssertTrue(a.contains("--offline"))
        func value(_ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
        XCTAssertEqual(value("--port"), "8123")
        XCTAssertEqual(value("--host"), "127.0.0.1")
        XCTAssertEqual(value("--max-context"), "131072")
        XCTAssertEqual(value("--default-reasoning-effort"), "high")
        XCTAssertEqual(value("--max-cache-disk"), "10G")
        XCTAssertEqual(value("--served-model-name"), "splash/Qwen3.8-27B-8bit")
        XCTAssertTrue(a.contains("--persistent-cache"))
        XCTAssertFalse(Splash.serveArguments(SplashConfig(), offline: false).contains("--max-context"))
    }

    func testPortClashes() {
        var cfg = AppConfig()
        cfg.upstream = "http://127.0.0.1:8000"
        cfg.splash.port = 8100
        XCTAssertNotNil(Ports.clash(for: .splash, port: 8000, cfg), "Splash can't take oMLX's port")
        XCTAssertNotNil(Ports.clash(for: .omlx, port: 11436, cfg), "oMLX can't take the gateway's port")
        XCTAssertNotNil(Ports.clash(for: .splash, port: 80, cfg), "privileged ports are refused")
        XCTAssertNil(Ports.clash(for: .splash, port: 8101, cfg))
        XCTAssertNil(Ports.clash(for: .splash, port: 8100, cfg), "its own port is fine")
    }

    func testSamplingPresetFillsOnlyWhatTheCallerLeftOut() {
        var p = ModelPreset()
        p.temperature = 1.0; p.topP = 0.95; p.topK = 20; p.minP = 0; p.presencePenalty = 1.5
        var payload: [String: Any] = ["model": "m", "temperature": 0.2, "max_tokens": 64000]
        Presets.apply(p, to: &payload, path: "/v1/chat/completions")
        XCTAssertEqual(payload["temperature"] as? Double, 0.2, "the caller's choice wins")
        XCTAssertEqual(payload["top_p"] as? Double, 0.95)
        XCTAssertEqual(payload["top_k"] as? Int, 20)
        XCTAssertEqual(payload["min_p"] as? Double, 0)
        XCTAssertEqual(payload["presence_penalty"] as? Double, 1.5)
        XCTAssertNil(payload["repetition_penalty"])

        var embed: [String: Any] = ["model": "m", "input": "x"]
        Presets.apply(p, to: &embed, path: "/v1/embeddings")
        XCTAssertNil(embed["top_p"])
    }

    func testOldConfigGainsSplashDefaultsAndKeepsPresets() throws {
        let old = #"{"port":11436,"upstream":"http://127.0.0.1:8000","presets":{"m":{"thinking":"off","minOutputTokens":0}}}"#
        let cfg = try JSONDecoder().decode(AppConfig.self, from: Data(old.utf8))
        XCTAssertEqual(cfg.splash.port, 8100)
        XCTAssertTrue(cfg.splash.key.hasPrefix("sk-"))
        XCTAssertEqual(cfg.preset(for: "m").thinking, "off")
        XCTAssertEqual(cfg.preset(for: "m").minOutputTokens, 0)
        XCTAssertNil(cfg.preset(for: "m").topP)
        XCTAssertEqual(cfg.omlxPort, 8000)
    }

    func testEngineChoiceAndPerEngineSlotsRoundTrip() throws {
        var cfg = AppConfig()
        XCTAssertEqual(cfg.engine, .omlx, "old configs keep using oMLX")
        cfg.engine = .splash
        cfg.slots = ["claude-sonnet-5": "splash/Qwen3.8-27B-8bit"]
        cfg.engineSlots = ["omlx": ["claude-sonnet-5": "Qwen3.8-27B-8bit"]]
        let back = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(cfg))
        XCTAssertEqual(back.engine, .splash)
        XCTAssertEqual(back.slots["claude-sonnet-5"], "splash/Qwen3.8-27B-8bit")
        XCTAssertEqual(back.engineSlots["omlx"]?["claude-sonnet-5"], "Qwen3.8-27B-8bit")
    }
}
