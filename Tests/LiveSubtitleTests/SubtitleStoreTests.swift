import XCTest
@testable import LiveSubtitle

@MainActor
final class SubtitleStoreTests: XCTestCase {
    func testVolatileUpsertKeepsSingleLinePerSpeaker() {
        let s = SubtitleStore()
        s.upsertVolatile(speaker: .other, text: "Hey")
        s.upsertVolatile(speaker: .other, text: "Hey can")
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertEqual(s.lines[0].original, "Hey can")
        XCTAssertFalse(s.lines[0].isFinal)
    }

    func testCommitFinalPromotesSameIdAndReturnsIt() {
        let s = SubtitleStore()
        s.upsertVolatile(speaker: .other, text: "Hey there")
        let volatileId = s.lines[0].id
        let finalId = s.commitFinal(speaker: .other, text: "Hey there.")
        XCTAssertEqual(finalId, volatileId)
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertTrue(s.lines[0].isFinal)
        XCTAssertEqual(s.lines[0].original, "Hey there.")
    }

    func testNextVolatileStartsNewLineAfterFinal() {
        let s = SubtitleStore()
        _ = s.commitFinal(speaker: .other, text: "One.")
        s.upsertVolatile(speaker: .other, text: "Two")
        XCTAssertEqual(s.lines.count, 2)
        XCTAssertFalse(s.lines[1].isFinal)
    }

    func testAttachTranslationById() {
        let s = SubtitleStore()
        let id = s.commitFinal(speaker: .other, text: "Hello.")
        s.attachTranslation(id: id, zh: "你好。")
        XCTAssertEqual(s.lines[0].translated, "你好。")
    }

    func testTwoSpeakersHaveIndependentVolatileLines() {
        let s = SubtitleStore()
        s.upsertVolatile(speaker: .other, text: "A")
        s.upsertVolatile(speaker: .me, text: "B")
        s.upsertVolatile(speaker: .other, text: "A2")
        XCTAssertEqual(s.lines.count, 2)
        XCTAssertEqual(s.lines.first { $0.speaker == .other }?.original, "A2")
        XCTAssertEqual(s.lines.first { $0.speaker == .me }?.original, "B")
    }

    func testStageVolatileDoesNotShowUntilFlush() {
        let s = SubtitleStore()
        s.stageVolatile(speaker: .other, text: "hel")
        s.stageVolatile(speaker: .other, text: "hello wor")
        XCTAssertTrue(s.lines.isEmpty)          // 未 flush 前不上屏
        s.flushVolatile()
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertEqual(s.lines[0].original, "hello wor")   // 合并:只留最后一次
    }

    func testFlushAppliesBothSpeakers() {
        let s = SubtitleStore()
        s.stageVolatile(speaker: .other, text: "hi there")
        s.stageVolatile(speaker: .me, text: "yes ok")
        s.flushVolatile()
        XCTAssertEqual(Set(s.lines.map(\.speaker)), [.other, .me])
    }

    func testCommitFinalClearsStagedVolatileForSpeaker() {
        let s = SubtitleStore()
        s.stageVolatile(speaker: .other, text: "stale")
        _ = s.commitFinal(speaker: .other, text: "final text")
        s.flushVolatile()                        // 陈旧 volatile 不应再造一行
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertEqual(s.lines[0].original, "final text")
        XCTAssertTrue(s.lines[0].isFinal)
    }
}
