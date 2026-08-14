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
        XCTAssertFalse(s.isRunning)
        XCTAssertTrue(s.translateVolatile)     // 默认开(边说边译)
        XCTAssertEqual(s.meetingLanguage, .english)
        XCTAssertEqual(s.sessionLanguage, .english)
    }

    // MARK: - 声纹判定阈值(设置页可调)

    /// 默认值必须等于 P6c 实测标定值,且与判定侧的真值来源同源 ——
    /// 设置页不该悄悄用另一套数把 probes 标定的结论覆盖掉。
    func testThresholdDefaultsMatchProbeCalibration() {
        let s = SubtitleStore(defaults: freshSuite())
        XCTAssertEqual(s.thresholdMe, 0.60, accuracy: 0.0001)
        XCTAssertEqual(s.thresholdCluster, 0.50, accuracy: 0.0001)
        XCTAssertEqual(s.thresholdMe, Double(SpeakerAttributor.defaultThresholdMe), accuracy: 0.0001)
        XCTAssertEqual(s.thresholdCluster, Double(SpeakerAttributor.defaultThresholdCluster), accuracy: 0.0001)
    }

    func testThresholdsPersistAcrossInstances() {
        let suite = freshSuite()
        let s1 = SubtitleStore(defaults: suite)
        s1.thresholdMe = 0.75
        s1.thresholdCluster = 0.65
        let s2 = SubtitleStore(defaults: suite)
        XCTAssertEqual(s2.thresholdMe, 0.75, accuracy: 0.0001)
        XCTAssertEqual(s2.thresholdCluster, 0.65, accuracy: 0.0001)
    }

    /// θ_me > θ_cluster 是 spec §2 的刻意不对称(把别人认成「我」比漏认更糟)。
    /// 用户在设置页只能碰这两根滑杆,所以不变式必须在 store 这一层守死。
    func testThresholdInvariantHoldsUnderUIEdits() {
        let s = SubtitleStore(defaults: freshSuite())

        // 1) 把 θ_cluster 顶到 θ_me 之上 → 被压回 θ_me 之下,θ_me 纹丝不动
        s.thresholdCluster = 0.90
        XCTAssertEqual(s.thresholdMe, 0.60, accuracy: 0.0001, "θ_me 是锚,不该被 θ_cluster 的调整带跑")
        XCTAssertGreaterThan(s.thresholdMe, s.thresholdCluster)

        // 2) 把 θ_me 压到 θ_cluster 之下 → θ_cluster 跟着降
        s.thresholdMe = 0.60
        s.thresholdCluster = 0.55
        s.thresholdMe = 0.40
        XCTAssertEqual(s.thresholdMe, 0.40, accuracy: 0.0001)
        XCTAssertGreaterThan(s.thresholdMe, s.thresholdCluster)

        // 3) 扫遍滑杆能产生的每一个组合,不变式恒成立
        let steps = stride(from: SubtitleStore.thresholdRange.lowerBound,
                           through: SubtitleStore.thresholdRange.upperBound,
                           by: SubtitleStore.thresholdStep)
        for v in steps {
            for w in steps {
                s.thresholdMe = v
                s.thresholdCluster = w
                XCTAssertGreaterThan(s.thresholdMe, s.thresholdCluster,
                                     "θ_me=\(v) θ_cluster=\(w) 之后不变式被破坏")
                XCTAssertTrue(SubtitleStore.thresholdRange.contains(s.thresholdMe))
                XCTAssertTrue(SubtitleStore.thresholdRange.contains(s.thresholdCluster))
            }
        }
    }

    /// 落盘的值可能来自旧版本/手改的 plist:init 也要规范化,而不是原样信任。
    func testCorruptPersistedThresholdsAreNormalizedOnLoad() {
        let suite = freshSuite()
        suite.set(0.10, forKey: "ls.thresholdMe")        // 低于区间下限
        suite.set(0.95, forKey: "ls.thresholdCluster")   // 高于上限,且高于 θ_me
        let s = SubtitleStore(defaults: suite)
        XCTAssertTrue(SubtitleStore.thresholdRange.contains(s.thresholdMe))
        XCTAssertTrue(SubtitleStore.thresholdRange.contains(s.thresholdCluster))
        XCTAssertGreaterThan(s.thresholdMe, s.thresholdCluster)
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
        // 没开过字幕时,"本场"跟随设置 —— 否则中文用户重启后第一屏会按英文渲染译文栏
        XCTAssertEqual(s2.sessionLanguage, .chinese)
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
        s.sessionLanguage = .chinese
        // 中文会议无译文:任何模式都退化为纯原文,否则终句永远卡「翻译中…」
        for mode in DisplayMode.allCases {
            s.displayMode = mode
            XCTAssertEqual(s.effectiveDisplayMode, .originalOnly, "\(mode) 下中文会议应退化为原文")
        }
        // 英文会议照旧透传
        s.sessionLanguage = .english
        for mode in DisplayMode.allCases {
            s.displayMode = mode
            XCTAssertEqual(s.effectiveDisplayMode, mode)
        }
    }

    func testEffectiveDisplayModeFollowsSessionNotSetting() {
        let s = SubtitleStore(defaults: freshSuite())
        s.displayMode = .both
        s.sessionLanguage = .english          // 屏上是英文会议的行,带译文
        s.meetingLanguage = .chinese          // 用户已为【下一场】选了中文
        // 改设置不该把屏上已有的英文行连带打回纯原文(译文会当场消失)
        XCTAssertEqual(s.effectiveDisplayMode, .both)
    }

    func testSessionLanguageAndIsRunningAreTransient() {
        let suite = freshSuite()
        let s1 = SubtitleStore(defaults: suite)
        s1.sessionLanguage = .chinese
        s1.isRunning = true
        // 同 layoutEditing:直接查底层 key,断言瞬态语义没被误加的持久化 didSet 破坏
        XCTAssertNil(suite.object(forKey: "ls.sessionLanguage"),
                     "sessionLanguage 不应写入 UserDefaults(瞬态语义被破坏)")
        XCTAssertNil(suite.object(forKey: "ls.isRunning"),
                     "isRunning 不应写入 UserDefaults(瞬态语义被破坏)")
        let s2 = SubtitleStore(defaults: suite)
        XCTAssertFalse(s2.isRunning)          // 启动永远 false
        XCTAssertEqual(s2.sessionLanguage, .english)   // 跟随未被改动的 meetingLanguage
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
