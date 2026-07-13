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
        let s2 = SubtitleStore(defaults: suite)
        XCTAssertEqual(s2.displayMode, .translatedOnly)
        XCTAssertEqual(s2.overlayMode, .mini)
        XCTAssertEqual(s2.opacity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(s2.fontSize, 28, accuracy: 0.0001)
        XCTAssertTrue(s2.pinned)
        XCTAssertEqual(s2.barWidth, 1200, accuracy: 0.0001)
        XCTAssertEqual(s2.deepSeekAPIKey, "sk-test-123")
        XCTAssertEqual(s2.obsidianVaultPath, "/Users/me/Vault")
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
