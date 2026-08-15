import XCTest
@testable import LiveSubtitle

@MainActor
final class SubtitleStoreTests: XCTestCase {
    /// 每条用例一个独立 suite —— 持久化用例之间不能互相看见对方写的键。
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "test.ls.\(UUID().uuidString)")!
    }

    func testVolatileUpsertKeepsSingleLinePerSpeaker() {
        let s = SubtitleStore()
        s.upsertVolatile(track: .system, text: "Hey")
        s.upsertVolatile(track: .system, text: "Hey can")
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertEqual(s.lines[0].original, "Hey can")
        XCTAssertFalse(s.lines[0].isFinal)
    }

    func testCommitFinalPromotesSameIdAndReturnsIt() {
        let s = SubtitleStore()
        s.upsertVolatile(track: .system, text: "Hey there")
        let volatileId = s.lines[0].id
        let finalId = s.commitFinal(track: .system, text: "Hey there.")
        XCTAssertEqual(finalId, volatileId)
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertTrue(s.lines[0].isFinal)
        XCTAssertEqual(s.lines[0].original, "Hey there.")
    }

    func testNextVolatileStartsNewLineAfterFinal() {
        let s = SubtitleStore()
        _ = s.commitFinal(track: .system, text: "One.")
        s.upsertVolatile(track: .system, text: "Two")
        XCTAssertEqual(s.lines.count, 2)
        XCTAssertFalse(s.lines[1].isFinal)
    }

    func testAttachTranslationById() {
        let s = SubtitleStore()
        let id = s.commitFinal(track: .system, text: "Hello.")
        s.attachTranslation(id: id, zh: "你好。")
        XCTAssertEqual(s.lines[0].translated, "你好。")
    }

    func testAttachSpeakerById() {
        let s = SubtitleStore()
        let id = s.commitFinal(track: .mic, text: "Hello.")
        XCTAssertEqual(s.lines[0].speaker.kind, .unresolved)   // 判定前
        s.attachSpeaker(id: id, speaker: SpeakerID(track: .mic, kind: .me))
        XCTAssertEqual(s.lines[0].speaker, SpeakerID(track: .mic, kind: .me))
    }

    func testAttachSpeakerMissingIdIsNoOp() {
        let s = SubtitleStore()
        _ = s.commitFinal(track: .mic, text: "Hello.")
        s.attachSpeaker(id: UUID(), speaker: SpeakerID(track: .mic, kind: .cluster(0)))
        XCTAssertEqual(s.lines[0].speaker.kind, .unresolved)   // 未知 id 不动任何行
    }

    func testTwoSpeakersHaveIndependentVolatileLines() {
        let s = SubtitleStore()
        s.upsertVolatile(track: .system, text: "A")
        s.upsertVolatile(track: .mic, text: "B")
        s.upsertVolatile(track: .system, text: "A2")
        XCTAssertEqual(s.lines.count, 2)
        XCTAssertEqual(s.lines.first { $0.speaker.track == .system }?.original, "A2")
        XCTAssertEqual(s.lines.first { $0.speaker.track == .mic }?.original, "B")
    }

    func testStageVolatileDoesNotShowUntilFlush() {
        let s = SubtitleStore()
        s.stageVolatile(track: .system, text: "hel")
        s.stageVolatile(track: .system, text: "hello wor")
        XCTAssertTrue(s.lines.isEmpty)          // 未 flush 前不上屏
        s.flushVolatile()
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertEqual(s.lines[0].original, "hello wor")   // 合并:只留最后一次
    }

    func testFlushAppliesBothSpeakers() {
        let s = SubtitleStore()
        s.stageVolatile(track: .system, text: "hi there")
        s.stageVolatile(track: .mic, text: "yes ok")
        s.flushVolatile()
        XCTAssertEqual(Set(s.lines.map(\.speaker.track)), [.system, .mic])
    }

    func testCommitFinalClearsStagedVolatileForSpeaker() {
        let s = SubtitleStore()
        s.stageVolatile(track: .system, text: "stale")
        _ = s.commitFinal(track: .system, text: "final text")
        s.flushVolatile()                        // 陈旧 volatile 不应再造一行
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertEqual(s.lines[0].original, "final text")
        XCTAssertTrue(s.lines[0].isFinal)
    }

    // MARK: - T2 翻译失败回退

    func testMarkTranslationFailedSetsFlagWhenUntranslated() {
        let s = SubtitleStore()
        let id = s.commitFinal(track: .system, text: "Hello.")
        s.markTranslationFailed(id: id)
        XCTAssertTrue(s.lines[0].translationFailed)
        XCTAssertNil(s.lines[0].translated)
    }

    func testMarkTranslationFailedNoOpWhenAlreadyTranslated() {
        let s = SubtitleStore()
        let id = s.commitFinal(track: .system, text: "Hello.")
        s.attachTranslation(id: id, zh: "你好。")
        s.markTranslationFailed(id: id)                 // 已有译文,不应打失败标
        XCTAssertFalse(s.lines[0].translationFailed)
        XCTAssertEqual(s.lines[0].translated, "你好。")
    }

    func testAttachTranslationClearsFailedFlag() {
        let s = SubtitleStore()
        let id = s.commitFinal(track: .system, text: "Hello.")
        s.markTranslationFailed(id: id)
        s.attachTranslation(id: id, zh: "你好。")         // 成功回填应清除失败标
        XCTAssertFalse(s.lines[0].translationFailed)
        XCTAssertEqual(s.lines[0].translated, "你好。")
    }

    // MARK: - T1 边说边译(中间态翻译)守卫

    func testCurrentVolatileTextReflectsLatestVolatile() {
        let s = SubtitleStore()
        XCTAssertNil(s.currentVolatileText(track: .system))
        s.upsertVolatile(track: .system, text: "I think we")
        XCTAssertEqual(s.currentVolatileText(track: .system), "I think we")
    }

    func testAttachVolatileTranslationAppliesWhenTextMatches() {
        let s = SubtitleStore()
        s.upsertVolatile(track: .system, text: "I think we")
        s.attachVolatileTranslation(track: .system, sourceText: "I think we", zh: "我认为我们")
        XCTAssertEqual(s.lines[0].translated, "我认为我们")
    }

    func testAttachVolatileTranslationDroppedWhenTextChanged() {
        let s = SubtitleStore()
        s.upsertVolatile(track: .system, text: "I think we should")   // 原文已生长
        s.attachVolatileTranslation(track: .system, sourceText: "I think we", zh: "我认为我们")  // 过期片段
        XCTAssertNil(s.lines[0].translated)                            // 不应贴过期译文
    }

    func testAttachVolatileTranslationDroppedAfterFinal() {
        let s = SubtitleStore()
        s.upsertVolatile(track: .system, text: "I think we")
        _ = s.commitFinal(track: .system, text: "I think we should go.")   // 已定稿,volatileIndex 清空
        s.attachVolatileTranslation(track: .system, sourceText: "I think we", zh: "我认为我们")
        XCTAssertNil(s.lines[0].translated)                            // 不应回填到已定稿行
    }

    // MARK: - 半句临时译文(provisional)在定稿后的处理

    func testCommitFinalCarriesProvisionalVolatileTranslation() {
        let s = SubtitleStore()
        s.upsertVolatile(track: .system, text: "I think we")
        s.attachVolatileTranslation(track: .system, sourceText: "I think we", zh: "我认为我们")
        XCTAssertTrue(s.lines[0].translationProvisional)
        _ = s.commitFinal(track: .system, text: "I think we should cancel.")
        XCTAssertEqual(s.lines[0].translated, "我认为我们")   // 半句译文暂留(平滑过渡)
        XCTAssertTrue(s.lines[0].translationProvisional)     // 仍是临时,未定稿
    }

    func testMarkFailedClearsProvisionalTranslation() {
        let s = SubtitleStore()
        s.upsertVolatile(track: .system, text: "I think we")
        s.attachVolatileTranslation(track: .system, sourceText: "I think we", zh: "我认为我们")
        let id = s.commitFinal(track: .system, text: "I think we should cancel.")
        s.markTranslationFailed(id: id)                      // 终句重译失败
        XCTAssertNil(s.lines[0].translated)                  // 清掉过期半句译文,别当定稿译文
        XCTAssertTrue(s.lines[0].translationFailed)          // 回退显原文
        XCTAssertFalse(s.lines[0].translationProvisional)
    }

    func testAttachTranslationClearsProvisional() {
        let s = SubtitleStore()
        s.upsertVolatile(track: .system, text: "I think we")
        s.attachVolatileTranslation(track: .system, sourceText: "I think we", zh: "我认为我们")
        let id = s.commitFinal(track: .system, text: "I think we should cancel.")
        s.attachTranslation(id: id, zh: "我认为我们应该取消。")   // 终句成句译文到位
        XCTAssertEqual(s.lines[0].translated, "我认为我们应该取消。")
        XCTAssertFalse(s.lines[0].translationProvisional)
    }

    // MARK: - 保留上限 + O(1) 索引在截断后仍正确

    func testLinesCappedAndLatestStillLocatable() {
        let s = SubtitleStore()
        var lastID = UUID()
        for k in 0..<2100 { lastID = s.commitFinal(track: .system, text: "line \(k)") }
        XCTAssertLessThanOrEqual(s.lines.count, 2000)          // 超限被截断
        XCTAssertEqual(s.lines.last?.original, "line 2099")    // 最新行保留
        s.attachTranslation(id: lastID, zh: "最后一行")          // 截断后 id→index 仍能定位
        XCTAssertEqual(s.lines.last?.translated, "最后一行")
    }

    func testVolatileSurvivesTrim() {
        let s = SubtitleStore()
        for k in 0..<2100 { _ = s.commitFinal(track: .system, text: "f\(k)") }
        s.upsertVolatile(track: .mic, text: "hello")          // 新中间态在尾部,不应被截断影响
        XCTAssertEqual(s.currentVolatileText(track: .mic), "hello")
        s.attachVolatileTranslation(track: .mic, sourceText: "hello", zh: "你好")
        XCTAssertEqual(s.lines.last(where: { $0.speaker.track == .mic })?.translated, "你好")
    }

    // MARK: - 会话边界(beginSession)

    // 每行盖当场的章;导出据此分段(见 ObsidianExporter.lastSessionLines)
    func testLinesAreStampedWithSessionID() {
        let s = SubtitleStore()
        let first = s.sessionID
        _ = s.commitFinal(track: .system, text: "第一场")
        s.beginSession(language: .chinese)
        XCTAssertNotEqual(s.sessionID, first)
        _ = s.commitFinal(track: .system, text: "第二场")
        XCTAssertEqual(s.lines[0].sessionID, first)
        XCTAssertEqual(s.lines[1].sessionID, s.sessionID)
    }

    // 停止→重开不得销毁还没导出的上一场:主按钮上两下点掉一整场会议,代价太大
    func testBeginSessionKeepsHistory() {
        let s = SubtitleStore()
        let id = s.commitFinal(track: .system, text: "hello")
        s.attachTranslation(id: id, zh: "你好")
        s.beginSession(language: .chinese)
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertEqual(s.lines[0].translated, "你好")
    }

    // 上一场遗留的灰字行不得被本场复用:否则本场第一句会去改写一条盖着上一场章的行
    func testBeginSessionDoesNotReuseStaleVolatileLine() {
        let s = SubtitleStore()
        s.upsertVolatile(track: .mic, text: "上一场没说完")
        let stale = s.lines[0].id
        s.beginSession(language: .chinese)
        let id = s.commitFinal(track: .mic, text: "本场第一句")
        XCTAssertNotEqual(id, stale)
        XCTAssertEqual(s.lines.count, 2)
        XCTAssertEqual(s.lines[1].sessionID, s.sessionID)
        XCTAssertFalse(s.lines[0].isFinal)          // 遗留灰字仍是灰字,不会被本场定稿
    }

    // 本场是全新 clusterer(簇号从 0 重编),本场的「说话人 2」与上一场多半不是同一个人,
    // 留着改名映射 = 自信地叫错人(与 speakerNames 不持久化同一条理由)。
    // 但作废的时刻是【本场第一条终句】,不是 beginSession —— 见下一条。
    func testFirstFinalOfNewSessionClearsRenames() {
        let s = SubtitleStore()
        let speaker = SpeakerID(track: .system, kind: .cluster(1))
        s.rename(speaker, to: "张三")
        s.beginSession(language: .english)
        _ = s.commitFinal(track: .system, text: "本场第一句")
        XCTAssertTrue(s.speakerNames.isEmpty)
        XCTAssertEqual(s.displayName(for: speaker), "说话人 2")
    }

    // 改名的作废时刻必须与导出锚点同步。停止→(误)重开→本场还没出终句时导出,
    // 取的仍是上一场的行(ObsidianExporter.lastSessionLines 锚在最后一条终句);
    // 若 beginSession 当场清了映射,这一篇就会拿空映射去导上一场,「老王」变回「说话人 2」。
    func testRenamesSurviveUntilNewSessionProducesAFinal() {
        let s = SubtitleStore()
        let speaker = SpeakerID(track: .system, kind: .cluster(1))
        _ = s.commitFinal(track: .system, text: "上一场")
        s.rename(speaker, to: "老王")

        s.beginSession(language: .english)                  // 停止 → 重开
        s.upsertVolatile(track: .mic, text: "本场还在说")     // 灰字不挪锚点
        XCTAssertEqual(s.speakerNames[speaker.kind], "老王", "本场还没出终句,上一场的改名不该没")
        XCTAssertEqual(s.displayName(for: speaker), "老王")

        _ = s.commitFinal(track: .mic, text: "本场第一句")     // 锚点挪到本场 → 同一刻作废
        XCTAssertTrue(s.speakerNames.isEmpty)
    }

    // MARK: - 最短判定句长(P6d)

    func testMinUtteranceDefaultsToProbeValueAndPersists() {
        let suite = freshSuite()
        let s1 = SubtitleStore(defaults: suite)
        XCTAssertEqual(s1.minUtteranceSeconds, SpeakerAttributor.defaultMinDuration, accuracy: 0.0001)
        s1.minUtteranceSeconds = 3.5
        XCTAssertEqual(SubtitleStore(defaults: suite).minUtteranceSeconds, 3.5, accuracy: 0.0001)
    }

    // 越界值(手改 plist / 旧版本 / 另一台机器同步过来)必须被夹回区间,不能直接喂给判定器
    func testMinUtteranceIsClampedToRange() {
        let s = SubtitleStore(defaults: freshSuite())
        s.minUtteranceSeconds = 99
        XCTAssertEqual(s.minUtteranceSeconds, SubtitleStore.minUtteranceRange.upperBound, accuracy: 0.0001)
        s.minUtteranceSeconds = -5
        XCTAssertEqual(s.minUtteranceSeconds, SubtitleStore.minUtteranceRange.lowerBound, accuracy: 0.0001)
    }

    // 只清一次:本场后续的改名不该被上一场遗留的「待作废」标记连坐清掉
    func testRenameExpiryFiresOnlyOnce() {
        let s = SubtitleStore()
        let speaker = SpeakerID(track: .system, kind: .cluster(0))
        s.rename(speaker, to: "上一场的名字")
        s.beginSession(language: .english)
        _ = s.commitFinal(track: .system, text: "第一句")     // 作废发生在这里
        s.rename(speaker, to: "本场的名字")
        _ = s.commitFinal(track: .system, text: "第二句")
        XCTAssertEqual(s.speakerNames[speaker.kind], "本场的名字")
    }
}
