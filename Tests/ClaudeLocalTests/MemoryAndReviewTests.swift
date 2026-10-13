import XCTest
@testable import LLM_Switcher

final class MemoryAndReviewTests: XCTestCase {
    private let gb: Int64 = 1 << 30
    private func holder(_ e: EngineKind, _ m: String, _ g: Int64, busy: Bool = false) -> MemoryGuard.Holder {
        .init(engine: e, model: m, bytes: g * gb, busy: busy)
    }

    // MARK: memory guard

    func testFitsGoesAhead() {
        let d = MemoryGuard.decide(target: "big", need: 40 * gb, available: 80 * gb,
                                   holders: [holder(.splash, "s", 30)], mode: .unload)
        XCTAssertEqual(d, .go)
    }

    func testOffAndUnknownSizeGoAhead() {
        XCTAssertEqual(MemoryGuard.decide(target: "x", need: 100 * gb, available: 10 * gb,
                                          holders: [holder(.splash, "s", 30)], mode: .off), .go)
        XCTAssertEqual(MemoryGuard.decide(target: "x", need: 0, available: 10 * gb,
                                          holders: [holder(.splash, "s", 30)], mode: .unload), .go)
    }

    func testNothingToFreeGoesAhead() {
        XCTAssertEqual(MemoryGuard.decide(target: "x", need: 100 * gb, available: 10 * gb, holders: [], mode: .unload), .go)
    }

    func testFreesBiggestFirstOnlyAsMuchAsNeeded() {
        // Needs 77 + 4 headroom = 81; 40 free. Freeing the 43 GB Splash model is enough.
        let holders = [holder(.omlx, "small", 10), holder(.splash, "s27", 43)]
        let d = MemoryGuard.decide(target: "flash", need: 77 * gb, available: 40 * gb, holders: holders, mode: .unload)
        XCTAssertEqual(d, .free([holder(.splash, "s27", 43)]))
    }

    func testFreesEverythingWhenEvenThatIsNotEnough() {
        let holders = [holder(.omlx, "a", 5), holder(.splash, "b", 5)]
        guard case .free(let chosen) = MemoryGuard.decide(target: "x", need: 100 * gb, available: 10 * gb, holders: holders, mode: .unload) else {
            return XCTFail("expected free")
        }
        XCTAssertEqual(Set(chosen.map(\.model)), ["a", "b"])
    }

    func testRefuseModeExplains() {
        let d = MemoryGuard.decide(target: "flash", need: 77 * gb, available: 40 * gb,
                                   holders: [holder(.splash, "s27", 43)], mode: .refuse)
        guard case .refuse(let why) = d else { return XCTFail("expected refuse") }
        XCTAssertTrue(why.contains("flash") && why.contains("s27") && why.contains("Memory guard"), why)
    }

    func testBusyModelIsNeverCutOff() {
        let d = MemoryGuard.decide(target: "flash", need: 77 * gb, available: 40 * gb,
                                   holders: [holder(.splash, "s27", 43, busy: true)], mode: .unload)
        guard case .refuse(let why) = d else { return XCTFail("expected refuse") }
        XCTAssertTrue(why.contains("busy"), why)
    }

    func testIdleModelsAreFreedBeforeRefusingForABusyOne() {
        // Needs 18 (14 + 4 headroom), 1 free. Busy A is biggest, but idle B + C make room.
        let holders = [holder(.omlx, "A", 10, busy: true), holder(.omlx, "B", 8), holder(.splash, "C", 10)]
        guard case .free(let chosen) = MemoryGuard.decide(target: "x", need: 14 * gb, available: 1 * gb, holders: holders, mode: .unload) else {
            return XCTFail("expected free")
        }
        XCTAssertEqual(Set(chosen.map(\.model)), ["B", "C"])
    }

    func testBusyModelRefusedOnlyWhenIdleOnesAreNotEnough() {
        let holders = [holder(.omlx, "A", 40, busy: true), holder(.omlx, "B", 2)]
        guard case .refuse(let why) = MemoryGuard.decide(target: "x", need: 30 * gb, available: 1 * gb, holders: holders, mode: .unload) else {
            return XCTFail("expected refuse")
        }
        XCTAssertTrue(why.contains("A") && why.contains("busy"), why)
    }

    func testOnlyBusyHoldersAndNothingIdleToFree() {
        // Nothing idle and the busy one is needed: refuse rather than go ahead into swap.
        let d = MemoryGuard.decide(target: "x", need: 30 * gb, available: 1 * gb,
                                   holders: [holder(.splash, "S", 40, busy: true)], mode: .unload)
        guard case .refuse = d else { return XCTFail("expected refuse, got \(d)") }
    }

    func testPenaltiesCountAsTuned() {
        var p = ModelPreset()
        p.repetitionPenalty = 1.05
        XCTAssertTrue(p.hasSampling)
    }

    func testShellIsKilledWhenCancelled() async {
        let t0 = Date()
        let task = Task { await ReviewLoop.shell("sleep 60", folder: FileManager.default.temporaryDirectory, timeout: 120) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        task.cancel()
        let (code, _) = await task.value
        XCTAssertNotEqual(code, 0)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 10, "Stop must not wait for the command's own timeout")
    }

    func testCancelKillsGrandchildrenToo() async throws {
        // zsh -> zsh -> sleep, like zsh -> swift -> xctest.
        let marker = "61.25"
        let task = Task { await ReviewLoop.shell("/bin/zsh -c 'sleep \(marker)'", folder: FileManager.default.temporaryDirectory, timeout: 120) }
        try await Task.sleep(nanoseconds: 800_000_000)
        task.cancel()
        _ = await task.value
        try await Task.sleep(nanoseconds: 300_000_000)
        let pg = Process()
        pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pg.arguments = ["-f", "sleep \(marker)"]
        let out = Pipe(); pg.standardOutput = out
        try pg.run(); pg.waitUntilExit()
        let left = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertTrue(left.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "still running: \(left)")
    }

    func testCancelBeforeStartIsNotLost() async {
        let t0 = Date()
        let task = Task { await ReviewLoop.shell("sleep 30", folder: FileManager.default.temporaryDirectory, timeout: 60) }
        task.cancel()                       // likely before the command has started
        let (code, _) = await task.value
        XCTAssertNotEqual(code, 0)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 10)
    }

    func testShellKeepsOutputOfFastCommands() async {
        let (code, out) = await ReviewLoop.shell("print '7 passed, 3 failed'", folder: FileManager.default.temporaryDirectory, timeout: 30)
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.contains("7 passed, 3 failed"), out)
    }

    func testMemoryGuardSettingDecodesAndDefaults() throws {
        XCTAssertEqual(try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8)).memoryGuard, .unload)
        let c = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"memoryGuard":"refuse"}"#.utf8))
        XCTAssertEqual(c.memoryGuard, .refuse)
        let bad = try JSONDecoder().decode(AppConfig.self, from: Data(#"{"memoryGuard":"nonsense","port":1234}"#.utf8))
        XCTAssertEqual(bad.memoryGuard, .unload)
        XCTAssertEqual(bad.port, 1234)
    }

    func testAvailableBytesIsSane() {
        let a = MemoryGuard.availableBytes()
        XCTAssertGreaterThan(a, 0)
        XCTAssertLessThanOrEqual(a, Int64(ProcessInfo.processInfo.physicalMemory))
    }

    // MARK: tuned presets

    func testPresetHasSampling() {
        var p = ModelPreset()
        XCTAssertFalse(p.hasSampling)
        p.thinking = "high"; p.minOutputTokens = 32000
        XCTAssertFalse(p.hasSampling, "thinking and length alone aren't sampling")
        p.topK = 20
        XCTAssertTrue(p.hasSampling)
    }

    // MARK: review loop screenshots

    func testUserContentWithoutImageIsPlainText() {
        XCTAssertEqual(ReviewLoop.userContent("hi", nil) as? String, "hi")
    }

    func testUserContentWithImageIsOpenAIImagePart() throws {
        let parts = try XCTUnwrap(ReviewLoop.userContent("look", Data([0x89, 0x50, 0x4E, 0x47])) as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["type"] as? String, "text")
        XCTAssertEqual(parts[0]["text"] as? String, "look")
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
        let url = (parts[1]["image_url"] as? [String: Any])?["url"] as? String
        XCTAssertEqual(url, "data:image/png;base64,iVBORw==")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: ["content": parts]))
    }

    func testReviewPromptMentionsScreenshotOnlyWhenAttached() {
        XCTAssertFalse(ReviewLoop.reviewPrompt("t", "c", "").contains("screenshot"))
        XCTAssertTrue(ReviewLoop.reviewPrompt("t", "c", "", screenshot: true).contains("screenshot"))
    }

    func testShellPassesEnvironmentAndTimesOut() async {
        let dir = FileManager.default.temporaryDirectory
        let (code, out) = await ReviewLoop.shell("print -r -- $OUT", folder: dir, env: ["OUT": "/tmp/x.png"], timeout: 30)
        XCTAssertEqual(code, 0)
        XCTAssertTrue(out.contains("/tmp/x.png"), out)
        let (slow, _) = await ReviewLoop.shell("sleep 30", folder: dir, timeout: 1)
        XCTAssertEqual(slow, 124)
    }
}
