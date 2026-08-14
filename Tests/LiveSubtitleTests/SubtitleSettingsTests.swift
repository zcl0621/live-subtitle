import XCTest
@testable import LiveSubtitle

@MainActor
final class SubtitleSettingsTests: XCTestCase {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "test.ls.\(UUID().uuidString)")!
    }

    func testDefaultsWhenEmpty() {
        let s = SubtitleStore(defaults: freshSuite())
        XCTAssertEqual(s.displayMode, .both)
        XCTAssertEqual(s.overlayMode, .bar)
        XCTAssertEqual(s.opacity, 0.82, accuracy: 0.0001)
        XCTAssertEqual(s.fontSize, 22, accuracy: 0.0001)
        XCTAssertFalse(s.pinned)
        XCTAssertEqual(s.barWidth, 900, accuracy: 0.0001)
        XCTAssertEqual(s.deepSeekAPIKey, "")
        XCTAssertEqual(s.obsidianVaultPath, "")
        XCTAssertFalse(s.layoutEditing)
        XCTAssertTrue(s.translateVolatile)     // 默认开(边说边译)
        XCTAssertEqual(s.meetingLanguage, .english)
    }

    func testSettingsPersistAcrossInstances() {
        let suite = freshSuite()
        let s1 = SubtitleStore(defaults: suite)
        s1.displayMode = .translatedOnly
        s1.overlayMode = .mini
        s1.opacity = 0.5
        s1.fontSize = 28
        s1.pinned = true
        s1.barWidth = 1200
        s1.deepSeekAPIKey = "sk-test-123"
        s1.obsidianVaultPath = "/Users/me/Vault"
        s1.translateVolatile = false
        s1.meetingLanguage = .chinese
        let s2 = SubtitleStore(defaults: suite)
        XCTAssertEqual(s2.displayMode, .translatedOnly)
        XCTAssertEqual(s2.overlayMode, .mini)
        XCTAssertEqual(s2.opacity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(s2.fontSize, 28, accuracy: 0.0001)
        XCTAssertTrue(s2.pinned)
        XCTAssertEqual(s2.barWidth, 1200, accuracy: 0.0001)
        XCTAssertEqual(s2.deepSeekAPIKey, "sk-test-123")
        XCTAssertEqual(s2.obsidianVaultPath, "/Users/me/Vault")
        XCTAssertFalse(s2.translateVolatile)
        XCTAssertEqual(s2.meetingLanguage, .chinese)
    }

    // MARK: - 会议语种(Task 7)

    func testMeetingLanguageNeedsTranslation() {
        // 用户约束:一个会议只有一种语言,中文会议不翻译。
        XCTAssertTrue(MeetingLanguage.english.needsTranslation)
        XCTAssertFalse(MeetingLanguage.chinese.needsTranslation)
    }

    func testMeetingLanguageLocaleMapping() {
        XCTAssertEqual(MeetingLanguage.english.locale.identifier, "en-US")
        XCTAssertEqual(MeetingLanguage.chinese.locale.identifier, "zh-CN")
        // 标识符须能解析成真实语言/地区(拼错会静默退化成空语言,识别器构建后才炸)
        XCTAssertEqual(MeetingLanguage.english.locale.language.languageCode?.identifier, "en")
        XCTAssertEqual(MeetingLanguage.chinese.locale.language.languageCode?.identifier, "zh")
        XCTAssertEqual(MeetingLanguage.chinese.locale.region?.identifier, "CN")
    }

    func testMeetingLanguageRawValuesAreStableStorageKeys() {
        // rawValue 落 UserDefaults,改动会让老用户的设置静默回退到 .english
        XCTAssertEqual(MeetingLanguage.english.rawValue, "english")
        XCTAssertEqual(MeetingLanguage.chinese.rawValue, "chinese")
        XCTAssertEqual(MeetingLanguage.allCases.count, 2)
    }

    func testMeetingLanguageFallsBackToEnglishOnGarbageValue() {
        let suite = freshSuite()
        suite.set("klingon", forKey: "ls.meetingLanguage")
        XCTAssertEqual(SubtitleStore(defaults: suite).meetingLanguage, .english)
    }

    func testEffectiveDisplayModeCollapsesForChineseMeeting() {
        let s = SubtitleStore(defaults: freshSuite())
        s.meetingLanguage = .chinese
        // 中文会议无译文:任何模式都退化为纯原文,否则终句永远卡「翻译中…」
        for mode in DisplayMode.allCases {
            s.displayMode = mode
            XCTAssertEqual(s.effectiveDisplayMode, .originalOnly, "\(mode) 下中文会议应退化为原文")
        }
        // 英文会议照旧透传
        s.meetingLanguage = .english
        for mode in DisplayMode.allCases {
            s.displayMode = mode
            XCTAssertEqual(s.effectiveDisplayMode, mode)
        }
    }

    func testLayoutEditingIsTransient() {
        let suite = freshSuite()
        let s1 = SubtitleStore(defaults: suite)
        s1.layoutEditing = true
        // 核心断言:瞬态属性【绝不落盘】——直接查底层 key 未被写入。
        // (仅断言 s2.layoutEditing==false 是恒真的:init 无条件置 false,
        //  即使误加了持久化 didSet 也照样通过,抓不到回归。)
        XCTAssertNil(suite.object(forKey: "ls.layoutEditing"),
                     "layoutEditing 不应写入 UserDefaults(瞬态语义被破坏)")
        let s2 = SubtitleStore(defaults: suite)
        XCTAssertFalse(s2.layoutEditing)
    }

    func testDisplayModeHelpers() {
        XCTAssertTrue(DisplayMode.both.showsOriginal)
        XCTAssertTrue(DisplayMode.both.showsTranslated)
        XCTAssertFalse(DisplayMode.translatedOnly.showsOriginal)
        XCTAssertTrue(DisplayMode.translatedOnly.showsTranslated)
        XCTAssertTrue(DisplayMode.originalOnly.showsOriginal)
        XCTAssertFalse(DisplayMode.originalOnly.showsTranslated)
    }
}
