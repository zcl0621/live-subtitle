import SwiftUI

/// 说话人的显示名与配色。抽出来单独一文件:bar / mini / 未来的导出都读同一份规则,
/// 免得配色在三处各写一遍再各自漂移。
extension SpeakerID {
    /// 默认显示名(不含用户改名)。改名映射见 `displayName(overrides:)` / `SubtitleStore.displayName(for:)`。
    ///
    /// `.unresolved` 退回轨别名而不是显示「…」:轨是 app 确定知道的事实(这句从麦克风来还是
    /// 从系统音来),声纹判定只是在此之上再细分。若模型下载失败或冷启动没跟上,
    /// `attributionReady` 会一直是 false,显示「…」等于把已知信息也丢了 —— 每行永久灰点。
    /// (ObsidianExporter 导出同一批行时直接复用本函数,显示「…」会让同一份数据出现两套说法。)
    /// 附带好处:判定落地时的过渡是 我→说话人 3,比 …→说话人 3 自然。
    var displayName: String {
        switch kind {
        case .me: "我"
        case .cluster(let n): "说话人 \(n + 1)"   // 簇号 0-based,人看的编号 1-based
        case .unresolved: track == .mic ? "我" : "对方"
        }
    }

    /// 用户改过名就用改的(空白名视同没改)。按 `kind` 查 —— 同一个簇在两条轨上是同一个人,
    /// 理由见 `SubtitleStore.speakerNames`。
    func displayName(overrides: [SpeakerID.Kind: String]) -> String {
        guard let custom = overrides[kind]?.trimmingCharacters(in: .whitespacesAndNewlines),
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

    /// 该说话人在色轮中的下标;`me` / `unresolved` 的颜色不走色轮,故为 nil。
    /// 单独暴露成 Int 是为了能在不碰 SwiftUI 渲染的前提下单测「配色只取决于簇号」。
    var paletteIndex: Int? {
        guard case .cluster(let n) = kind else { return nil }
        let count = Self.palette.count
        return ((n % count) + count) % count   // 簇号理论上非负,取模仍防一手负数下标崩溃
    }

    /// 标签底色:我=蓝,簇=色轮,判定中=按轨给旧配色(蓝/橙)。
    /// 判定中不用灰:与 displayName 同一个道理,轨是已知事实,
    /// 而且灰底配「我」这种确定的名字会读成「这条不确定」,反倒误导。
    var color: Color {
        switch kind {
        case .me: .blue
        case .cluster: Self.palette[paletteIndex ?? 0]
        case .unresolved: track == .mic ? .blue : .orange
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
