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

    // MARK: - T2 翻译失败回退

    func testMarkTranslationFailedSetsFlagWhenUntranslated() {
        let s = SubtitleStore()
        let id = s.commitFinal(speaker: .other, text: "Hello.")
        s.markTranslationFailed(id: id)
        XCTAssertTrue(s.lines[0].translationFailed)
        XCTAssertNil(s.lines[0].translated)
    }

    func testMarkTranslationFailedNoOpWhenAlreadyTranslated() {
        let s = SubtitleStore()
        let id = s.commitFinal(speaker: .other, text: "Hello.")
        s.attachTranslation(id: id, zh: "你好。")
        s.markTranslationFailed(id: id)                 // 已有译文,不应打失败标
        XCTAssertFalse(s.lines[0].translationFailed)
        XCTAssertEqual(s.lines[0].translated, "你好。")
    }

    func testAttachTranslationClearsFailedFlag() {
        let s = SubtitleStore()
        let id = s.commitFinal(speaker: .other, text: "Hello.")
        s.markTranslationFailed(id: id)
        s.attachTranslation(id: id, zh: "你好。")         // 成功回填应清除失败标
        XCTAssertFalse(s.lines[0].translationFailed)
        XCTAssertEqual(s.lines[0].translated, "你好。")
    }

    // MARK: - T1 边说边译(中间态翻译)守卫

    func testCurrentVolatileTextReflectsLatestVolatile() {
        let s = SubtitleStore()
        XCTAssertNil(s.currentVolatileText(speaker: .other))
        s.upsertVolatile(speaker: .other, text: "I think we")
        XCTAssertEqual(s.currentVolatileText(speaker: .other), "I think we")
    }

    func testAttachVolatileTranslationAppliesWhenTextMatches() {
        let s = SubtitleStore()
        s.upsertVolatile(speaker: .other, text: "I think we")
        s.attachVolatileTranslation(speaker: .other, sourceText: "I think we", zh: "我认为我们")
        XCTAssertEqual(s.lines[0].translated, "我认为我们")
    }

    func testAttachVolatileTranslationDroppedWhenTextChanged() {
        let s = SubtitleStore()
        s.upsertVolatile(speaker: .other, text: "I think we should")   // 原文已生长
        s.attachVolatileTranslation(speaker: .other, sourceText: "I think we", zh: "我认为我们")  // 过期片段
        XCTAssertNil(s.lines[0].translated)                            // 不应贴过期译文
    }

    func testAttachVolatileTranslationDroppedAfterFinal() {
        let s = SubtitleStore()
        s.upsertVolatile(speaker: .other, text: "I think we")
        _ = s.commitFinal(speaker: .other, text: "I think we should go.")   // 已定稿,volatileIndex 清空
        s.attachVolatileTranslation(speaker: .other, sourceText: "I think we", zh: "我认为我们")
        XCTAssertNil(s.lines[0].translated)                            // 不应回填到已定稿行
    }

    // MARK: - 半句临时译文(provisional)在定稿后的处理

    func testCommitFinalCarriesProvisionalVolatileTranslation() {
        let s = SubtitleStore()
        s.upsertVolatile(speaker: .other, text: "I think we")
        s.attachVolatileTranslation(speaker: .other, sourceText: "I think we", zh: "我认为我们")
        XCTAssertTrue(s.lines[0].translationProvisional)
        _ = s.commitFinal(speaker: .other, text: "I think we should cancel.")
        XCTAssertEqual(s.lines[0].translated, "我认为我们")   // 半句译文暂留(平滑过渡)
        XCTAssertTrue(s.lines[0].translationProvisional)     // 仍是临时,未定稿
    }

    func testMarkFailedClearsProvisionalTranslation() {
        let s = SubtitleStore()
        s.upsertVolatile(speaker: .other, text: "I think we")
        s.attachVolatileTranslation(speaker: .other, sourceText: "I think we", zh: "我认为我们")
        let id = s.commitFinal(speaker: .other, text: "I think we should cancel.")
        s.markTranslationFailed(id: id)                      // 终句重译失败
        XCTAssertNil(s.lines[0].translated)                  // 清掉过期半句译文,别当定稿译文
        XCTAssertTrue(s.lines[0].translationFailed)          // 回退显原文
        XCTAssertFalse(s.lines[0].translationProvisional)
    }

    func testAttachTranslationClearsProvisional() {
        let s = SubtitleStore()
        s.upsertVolatile(speaker: .other, text: "I think we")
        s.attachVolatileTranslation(speaker: .other, sourceText: "I think we", zh: "我认为我们")
        let id = s.commitFinal(speaker: .other, text: "I think we should cancel.")
        s.attachTranslation(id: id, zh: "我认为我们应该取消。")   // 终句成句译文到位
        XCTAssertEqual(s.lines[0].translated, "我认为我们应该取消。")
        XCTAssertFalse(s.lines[0].translationProvisional)
    }
}
