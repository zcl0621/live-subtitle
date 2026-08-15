import XCTest
@testable import LiveSubtitle

@MainActor
final class ObsidianExporterTests: XCTestCase {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "test.ls.\(UUID().uuidString)")!
    }

    private func line(_ speaker: SpeakerID, _ original: String, translated: String? = nil,
                      isFinal: Bool = true, session: UUID = UUID()) -> SubtitleLine {
        SubtitleLine(sessionID: session, speaker: speaker, original: original,
                     translated: translated, isFinal: isFinal)
    }

    // MARK: - 英文会议:原文 — 译文

    func testEnglishLineCarriesTranslationTail() {
        let rows = ObsidianExporter.transcriptMarkdown(from: [
            line(SpeakerID(track: .system, kind: .cluster(1)), "hello there", translated: "你好啊"),
        ])
        XCTAssertEqual(rows, "- **说话人 2**:hello there — 你好啊")
    }

    // MARK: - 中文会议:无译文,不留空的 " — " 尾巴

    func testChineseLineDegradesToOriginalOnly() {
        let rows = ObsidianExporter.transcriptMarkdown(from: [
            line(SpeakerID(track: .system, kind: .cluster(0)), "今天先对一下排期"),
        ])
        XCTAssertEqual(rows, "- **说话人 1**:今天先对一下排期")
        XCTAssertFalse(rows.contains(" — "), "中文会议不该出现译文分隔符")
        XCTAssertFalse(rows.hasSuffix(" — "))
    }

    // 译文是空白串(翻译返回空)时同样退化,不留尾巴
    func testBlankTranslationDegradesToOriginalOnly() {
        let rows = ObsidianExporter.transcriptMarkdown(from: [
            line(SpeakerID(track: .mic, kind: .me), "全都念完了", translated: "   "),
        ])
        XCTAssertEqual(rows, "- **我**:全都念完了")
    }

    // MARK: - 说话人名:与屏上同源(SpeakerID.displayName + 改名映射)

    func testSpeakerNamesFollowSpeakerIDNotTrack() {
        // 从 system 轨来的「我」(外放漏音场景)导出也必须是「我」,不能按轨压成「对方」
        let rows = ObsidianExporter.transcriptMarkdown(from: [
            line(SpeakerID(track: .system, kind: .me), "that's me"),
            line(SpeakerID(track: .mic, kind: .cluster(2)), "someone else"),
            line(SpeakerID.unresolved(.system), "not judged yet"),
        ])
        XCTAssertEqual(rows, """
        - **我**:that's me
        - **说话人 3**:someone else
        - **对方**:not judged yet
        """)
    }

    func testRenameOverridesApplyToExport() {
        let cluster = SpeakerID(track: .system, kind: .cluster(1))
        let rows = ObsidianExporter.transcriptMarkdown(
            from: [line(cluster, "我说两句"), line(SpeakerID(track: .mic, kind: .me), "好的")],
            speakerNames: [cluster.kind: "张三", SpeakerID.Kind.me: "李四"]
        )
        XCTAssertEqual(rows, """
        - **张三**:我说两句
        - **李四**:好的
        """)
    }

    // 改名按 kind 生效,两条轨上的同一个簇一起改(与屏上一致)
    func testRenameAppliesAcrossTracksInExport() {
        let kind = SpeakerID.Kind.cluster(0)
        let rows = ObsidianExporter.transcriptMarkdown(
            from: [line(SpeakerID(track: .mic, kind: kind), "A"),
                   line(SpeakerID(track: .system, kind: kind), "B")],
            speakerNames: [kind: "老王"]
        )
        XCTAssertEqual(rows, "- **老王**:A\n- **老王**:B")
    }

    func testVolatileLinesAreExcluded() {
        let rows = ObsidianExporter.transcriptMarkdown(from: [
            line(SpeakerID.unresolved(.mic), "定稿了"),
            line(SpeakerID.unresolved(.mic), "还在说", isFinal: false),
        ])
        XCTAssertEqual(rows, "- **我**:定稿了")
    }

    // MARK: - 会话分段:一次会议一篇笔记

    func testLastSessionLinesKeepsOnlyNewestSession() {
        let s1 = UUID(), s2 = UUID()
        let all = [
            line(SpeakerID.unresolved(.system), "old english", translated: "旧译文", session: s1),
            line(SpeakerID.unresolved(.mic), "新一场第一句", session: s2),
            line(SpeakerID.unresolved(.system), "新一场第二句", session: s2),
        ]
        let kept = ObsidianExporter.lastSessionLines(all)
        XCTAssertEqual(kept.map(\.original), ["新一场第一句", "新一场第二句"])
        // 这正是 Task 7 评审发现的陷阱:上一场的 ` — 译文` 尾巴不得混进本场笔记
        let rows = ObsidianExporter.transcriptMarkdown(from: kept)
        XCTAssertFalse(rows.contains(" — "))
    }

    func testLastSessionLinesEmptyWithoutAnyFinalLine() {
        XCTAssertTrue(ObsidianExporter.lastSessionLines([]).isEmpty)
        XCTAssertTrue(ObsidianExporter.lastSessionLines([
            line(SpeakerID.unresolved(.mic), "灰字", isFinal: false),
        ]).isEmpty)
    }

    // 新会议刚开、只有灰字中间态时,锚点仍落在上一场的终句上 ——
    // 该导出的是上一场那批内容,而不是"本场 0 行,没有可导出的转录"。
    func testLastSessionLinesAnchorsOnLastFinalNotLastLine() {
        let s1 = UUID(), s2 = UUID()
        let all = [
            line(SpeakerID.unresolved(.system), "上一场终句", session: s1),
            line(SpeakerID.unresolved(.mic), "本场还没定稿", isFinal: false, session: s2),
        ]
        XCTAssertEqual(ObsidianExporter.lastSessionLines(all).map(\.original), ["上一场终句"])
    }

    // MARK: - 与 store 接线:同一场里改名 + 分段一起生效

    func testStoreLinesAreStampedWithCurrentSession() {
        let store = SubtitleStore(defaults: freshSuite())
        // 第一场:英文,带译文
        store.beginSession(language: .english)
        let id = store.commitFinal(track: .system, text: "hello")
        store.attachTranslation(id: id, zh: "你好")
        store.attachSpeaker(id: id, speaker: SpeakerID(track: .system, kind: .cluster(0)))

        // 第二场:中文
        store.beginSession(language: .chinese)
        let id2 = store.commitFinal(track: .mic, text: "今天开会")
        store.attachSpeaker(id: id2, speaker: SpeakerID(track: .mic, kind: .me))

        // 历史仍在(没被清空),但导出只收本场
        XCTAssertEqual(store.lines.count, 2)
        let rows = ObsidianExporter.transcriptMarkdown(
            from: ObsidianExporter.lastSessionLines(store.lines),
            speakerNames: store.speakerNames
        )
        XCTAssertEqual(rows, "- **我**:今天开会")
    }

    // MARK: - 笔记正文

    func testNoteBodyContainsSummaryAndTranscript() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ls-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let note = ObsidianExporter.Note(
            title: "周会",
            summary: "对了排期",
            transcriptMarkdown: ObsidianExporter.transcriptMarkdown(from: [
                line(SpeakerID(track: .system, kind: .cluster(0)), "今天先对一下排期"),
            ]),
            date: Date()
        )
        let url = try ObsidianExporter.write(note, toVaultPath: dir.path)
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("- **说话人 1**:今天先对一下排期"), content)
        XCTAssertFalse(content.contains(" — "), "中文会议的笔记不该出现译文分隔符")
    }
}
