import SwiftUI
import XCTest
@testable import LiveSubtitle

@MainActor
final class SpeakerDisplayTests: XCTestCase {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "test.ls.\(UUID().uuidString)")!
    }

    // MARK: - 默认显示名

    func testDisplayNameForMe() {
        XCTAssertEqual(SpeakerID(track: .mic, kind: .me).displayName, "我")
        XCTAssertEqual(SpeakerID(track: .system, kind: .me).displayName, "我")
    }

    // 簇号 0-based,给人看的编号 1-based
    func testDisplayNameForClusterIsOneBased() {
        XCTAssertEqual(SpeakerID(track: .system, kind: .cluster(0)).displayName, "说话人 1")
        XCTAssertEqual(SpeakerID(track: .system, kind: .cluster(4)).displayName, "说话人 5")
    }

    // 未判定退回轨别名,不显示「…」:模型下载失败/冷启动没跟上时 attributionReady 永假,
    // 显示「…」会把 app 确定知道的轨信息也丢掉,变成每行永久占位符。
    func testDisplayNameForUnresolvedFallsBackToTrack() {
        XCTAssertEqual(SpeakerID.unresolved(.mic).displayName, "我")
        XCTAssertEqual(SpeakerID.unresolved(.system).displayName, "对方")
    }

    // 与 ObsidianExporter 对同一批行的写法保持一致,免得同一份数据出现两套说法
    func testUnresolvedNamesMatchExporterConvention() {
        XCTAssertEqual(SpeakerID.unresolved(.mic).displayName, "我")
        XCTAssertEqual(SpeakerID.unresolved(.system).displayName, "对方")
    }

    // MARK: - 改名映射优先

    func testRenameOverridesDefaultName() {
        let store = SubtitleStore(defaults: freshSuite())
        let speaker = SpeakerID(track: .system, kind: .cluster(0))
        XCTAssertEqual(store.displayName(for: speaker), "说话人 1")
        store.rename(speaker, to: "老王")
        XCTAssertEqual(store.displayName(for: speaker), "老王")
    }

    // 改名只作用于被改的那一个;别的说话人不受影响
    func testRenameDoesNotLeakToOtherSpeakers() {
        let store = SubtitleStore(defaults: freshSuite())
        let a = SpeakerID(track: .system, kind: .cluster(0))
        let b = SpeakerID(track: .system, kind: .cluster(1))
        let me = SpeakerID(track: .mic, kind: .me)
        store.rename(a, to: "老王")
        XCTAssertEqual(store.displayName(for: b), "说话人 2")
        XCTAssertEqual(store.displayName(for: me), "我")
    }

    // 两条轨共用同一个 SpeakerClusterer、centroids 是单一数组,所以 .cluster(0) 无论
    // 出现在哪条轨都是同一个 centroid = 同一个人 —— 配色已按 kind 忽略轨(同色),
    // 改名也必须跟着走,否则用户看到两个同色同名的 chip,改一个只有一半的行更新。
    func testRenameAppliesAcrossTracksForSameCluster() {
        let store = SubtitleStore(defaults: freshSuite())
        let micCluster = SpeakerID(track: .mic, kind: .cluster(0))
        let systemCluster = SpeakerID(track: .system, kind: .cluster(0))
        // 前提:两者本来就同名同色
        XCTAssertEqual(micCluster.displayName, systemCluster.displayName)
        XCTAssertEqual(micCluster.color, systemCluster.color)

        store.rename(micCluster, to: "同事A")
        XCTAssertEqual(store.displayName(for: micCluster), "同事A")
        XCTAssertEqual(store.displayName(for: systemCluster), "同事A")
    }

    // 「我」同理:mic 轨和 system 轨上的 .me 是同一个人
    func testRenamingMeAppliesAcrossTracks() {
        let store = SubtitleStore(defaults: freshSuite())
        store.rename(SpeakerID(track: .mic, kind: .me), to: "张三")
        XCTAssertEqual(store.displayName(for: SpeakerID(track: .system, kind: .me)), "张三")
    }

    // 空白名 = 恢复默认,而不是把标签抹成空白
    func testRenameToBlankRestoresDefault() {
        let store = SubtitleStore(defaults: freshSuite())
        let speaker = SpeakerID(track: .system, kind: .cluster(2))
        store.rename(speaker, to: "老李")
        store.rename(speaker, to: "   ")
        XCTAssertEqual(store.displayName(for: speaker), "说话人 3")
        XCTAssertNil(store.speakerNames[speaker.kind])
    }

    func testRenameTrimsWhitespace() {
        let store = SubtitleStore(defaults: freshSuite())
        let speaker = SpeakerID(track: .system, kind: .cluster(0))
        store.rename(speaker, to: "  老王  ")
        XCTAssertEqual(store.displayName(for: speaker), "老王")
    }

    // overrides 里存了空白字符串(不经 rename 直接塞)也要退回默认名
    func testBlankOverrideFallsBackToDefault() {
        let speaker = SpeakerID(track: .system, kind: .cluster(0))
        XCTAssertEqual(speaker.displayName(overrides: [speaker.kind: "  "]), "说话人 1")
    }

    // MARK: - 改名是瞬态的

    // 跨会话簇号不稳定,持久化会张冠李戴 —— 改名不得进 UserDefaults,新实例必须是干净的
    func testRenamesAreTransientAcrossStoreInstances() {
        let suite = freshSuite()
        let speaker = SpeakerID(track: .system, kind: .cluster(0))
        let s1 = SubtitleStore(defaults: suite)
        s1.rename(speaker, to: "老王")
        XCTAssertEqual(s1.displayName(for: speaker), "老王")

        let s2 = SubtitleStore(defaults: suite)
        XCTAssertTrue(s2.speakerNames.isEmpty)
        XCTAssertEqual(s2.displayName(for: speaker), "说话人 1")
    }

    // 更硬的一条:defaults 里根本不该出现任何跟改名有关的键
    func testRenameWritesNothingToUserDefaults() {
        let suite = freshSuite()
        let before = suite.dictionaryRepresentation().keys.sorted()
        let store = SubtitleStore(defaults: suite)
        store.rename(SpeakerID(track: .system, kind: .cluster(0)), to: "老王")
        store.rename(SpeakerID(track: .mic, kind: .me), to: "我自己")
        let after = suite.dictionaryRepresentation().keys.sorted()
        XCTAssertEqual(before, after, "改名不该往 UserDefaults 里写任何东西")
    }

    // MARK: - 配色按簇号取模,稳定

    // 核心不变量:cluster(n) 的颜色只由 n 决定 —— 新说话人加入不会让已有人换色
    func testClusterColorDependsOnlyOnClusterNumber() {
        let zeroBefore = SpeakerID(track: .system, kind: .cluster(0)).paletteIndex
        // 模拟会话里陆续冒出 1…7 号说话人
        for n in 1...7 {
            _ = SpeakerID(track: .system, kind: .cluster(n)).paletteIndex
        }
        let zeroAfter = SpeakerID(track: .system, kind: .cluster(0)).paletteIndex
        XCTAssertEqual(zeroBefore, zeroAfter)
        XCTAssertEqual(zeroAfter, 0)
        // 颜色本身也不变
        XCTAssertEqual(SpeakerID(track: .system, kind: .cluster(0)).color,
                       SpeakerID.palette[0])
    }

    func testEachClusterBelowPaletteSizeGetsDistinctColor() {
        let count = SpeakerID.palette.count
        let indices = (0..<count).map { SpeakerID(track: .system, kind: .cluster($0)).paletteIndex }
        XCTAssertEqual(indices, (0..<count).map { Optional($0) })
        XCTAssertEqual(Set(indices).count, count)
    }

    // 超过色轮长度就取模复用,不越界
    func testClusterColorWrapsAroundPalette() {
        let count = SpeakerID.palette.count
        XCTAssertEqual(SpeakerID(track: .system, kind: .cluster(count)).paletteIndex, 0)
        XCTAssertEqual(SpeakerID(track: .system, kind: .cluster(count + 3)).paletteIndex, 3)
        XCTAssertEqual(SpeakerID(track: .system, kind: .cluster(count * 5 + 2)).color,
                       SpeakerID.palette[2])
    }

    // 配色与 track 无关:同一簇号在两条轨上是同一个颜色
    func testClusterColorIgnoresTrack() {
        XCTAssertEqual(SpeakerID(track: .mic, kind: .cluster(3)).color,
                       SpeakerID(track: .system, kind: .cluster(3)).color)
    }

    // 「我」恒定蓝;未判定按轨给旧配色(蓝/橙),不用灰
    // —— 灰底配「我」这种确定的名字会读成「这条不确定」,反倒误导。
    func testMeAndUnresolvedColors() {
        XCTAssertEqual(SpeakerID(track: .mic, kind: .me).color, .blue)
        XCTAssertEqual(SpeakerID(track: .system, kind: .me).color, .blue)
        XCTAssertEqual(SpeakerID.unresolved(.mic).color, .blue)
        XCTAssertEqual(SpeakerID.unresolved(.system).color, .orange)
        XCTAssertNil(SpeakerID(track: .mic, kind: .me).paletteIndex)
        XCTAssertNil(SpeakerID.unresolved(.mic).paletteIndex)
    }

    // MARK: - 可改名性

    // 未判定行虽然显示成「我/对方」,仍不可改名:它是「还没判出来」的占位身份,
    // 判定一回填这条行就变成别的 kind,改的名当场就跟丢了。
    func testUnresolvedIsNotRenamable() {
        XCTAssertFalse(SpeakerID.unresolved(.mic).isRenamable)
        XCTAssertTrue(SpeakerID(track: .mic, kind: .me).isRenamable)
        XCTAssertTrue(SpeakerID(track: .system, kind: .cluster(0)).isRenamable)
    }
}
