import SwiftUI

/// 说话人的显示名与配色。抽出来单独一文件:bar / mini / 未来的导出都读同一份规则,
/// 免得配色在三处各写一遍再各自漂移。
extension SpeakerID {
    /// 默认显示名(不含用户改名)。改名映射见 `displayName(overrides:)` / `SubtitleStore.displayName(for:)`。
    var displayName: String {
        switch kind {
        case .me: "我"
        case .cluster(let n): "说话人 \(n + 1)"   // 簇号 0-based,人看的编号 1-based
        case .unresolved: "…"
        }
    }

    /// 用户改过名就用改的(空白名视同没改)。
    func displayName(overrides: [SpeakerID: String]) -> String {
        guard let custom = overrides[self]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !custom.isEmpty
        else { return displayName }
        return custom
    }

    /// 能不能改名。`.unresolved` 是「还没判出来」的占位,不是一个人,改它没有意义
    /// —— 判定一回填这条行就变成别的身份了,改的名当场作废。
    var isRenamable: Bool {
        if case .unresolved = kind { return false }
        return true
    }

    /// 簇的稳定色轮。**必须按簇号取模,不能按出现顺序**:
    /// 会话中途冒出第 4 个人时,若按出现顺序分配,已有三人的颜色会整体错位重排,
    /// 用户刚记住「绿色是老王」就失效了。按簇号取模则每个簇的颜色一经确定终身不变。
    static let palette: [Color] = [.orange, .green, .purple, .pink, .teal, .indigo, .brown, .red]

    /// 该说话人在色轮中的下标;`me` / `unresolved` 用固定色,故为 nil。
    /// 单独暴露成 Int 是为了能在不碰 SwiftUI 渲染的前提下单测「配色只取决于簇号」。
    var paletteIndex: Int? {
        guard case .cluster(let n) = kind else { return nil }
        let count = Self.palette.count
        return ((n % count) + count) % count   // 簇号理论上非负,取模仍防一手负数下标崩溃
    }

    /// 标签底色:我=蓝(沿用现状),簇=色轮,判定中=灰。
    var color: Color {
        switch kind {
        case .me: .blue
        case .cluster: Self.palette[paletteIndex ?? 0]
        case .unresolved: .gray
        }
    }
}

extension VoiceprintProfile.Language {
    var displayName: String {
        switch self {
        case .chinese: "中文"
        case .english: "English"
        }
    }
}
