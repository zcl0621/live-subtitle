import Foundation

/// 路由用:哪条音频轨。承接旧 Speaker 在「每轨状态字典键」上的角色。
enum Track: String, Hashable, Sendable, CaseIterable {
    case mic     // 麦克风(旧 .me)
    case system  // 系统音(旧 .other)
}

/// 显示用:这句话是谁说的。
struct SpeakerID: Hashable, Sendable {
    let track: Track
    let kind: Kind

    enum Kind: Hashable, Sendable {
        case me              // 命中预注册声纹
        case cluster(Int)    // 会话内自动聚类
        case unresolved      // 判定中 / 音频太短
    }

    static func unresolved(_ track: Track) -> SpeakerID {
        SpeakerID(track: track, kind: .unresolved)
    }
}
enum DisplayMode: String, Sendable, CaseIterable { case originalOnly, both, translatedOnly }
enum OverlayMode: String, Sendable, CaseIterable { case bar, mini }

extension DisplayMode {
    var showsOriginal: Bool { self != .translatedOnly }
    var showsTranslated: Bool { self != .originalOnly }
}

/// 本场会议说的是哪种语言。一个会议只有一种语言(用户约束),开场选定后整场不变。
enum MeetingLanguage: String, Sendable, CaseIterable {
    case english
    case chinese

    /// 识别用 locale。连字符写法即 supportedLocales 条目的 bcp47 形式
    /// (实测两者 bcp47 相等、`AssetInventory.status` 均为 supported;P7 另验过中文可 headless 下载 + 识别)。
    var locale: Locale {
        switch self {
        case .english: Locale(identifier: "en-US")
        case .chinese: Locale(identifier: "zh-CN")
        }
    }

    /// 是否需要翻译。中文会议的原文已经是中文,译文无意义 —— 整条翻译链路都不该跑。
    /// 用 switch 而非 `self == .english`:将来加语种时编译器会逼着这里表态。
    var needsTranslation: Bool {
        switch self {
        case .english: true
        case .chinese: false
        }
    }

    var displayName: String {
        switch self {
        case .english: "English"
        case .chinese: "中文"
        }
    }
}

/// 跨 actor 的 Sendable 音频载体(不直接传 AVAudioPCMBuffer,后者非 Sendable)。
/// pcm 为已转换到 analyzer 目标格式(16k/Int16/单声道)的样本。
struct AudioFrame: Sendable {
    let pcm: [Int16]
    let track: Track
    let hostTime: UInt64
}

struct SubtitleLine: Identifiable, Sendable {
    let id: UUID
    /// 这行产自哪一场会议 —— `SubtitleStore.beginSession` 在开场那一刻换的章。
    /// 导出按它分段(一次会议一篇笔记),理由见 `ObsidianExporter.lastSessionLines`。
    /// 默认给一枚独有的新 id:手搓的行各自成场,不会被误并进别人的会议。
    let sessionID: UUID
    var speaker: SpeakerID
    var original: String
    var translated: String?
    var isFinal: Bool
    /// 翻译已尝试但失败(区别于「尚未翻译/翻译中」)。UI 据此回退显原文而非永久「翻译中…」。
    var translationFailed: Bool
    /// 当前 translated 来自中间态的半句译文(临时)。终句成句译文到位前为 true;
    /// 若终句重译失败,这份半句译文不可当作定稿译文,应回退显原文。
    var translationProvisional: Bool

    init(id: UUID = UUID(), sessionID: UUID = UUID(), speaker: SpeakerID, original: String,
         translated: String? = nil, isFinal: Bool = false,
         translationFailed: Bool = false, translationProvisional: Bool = false) {
        self.id = id; self.sessionID = sessionID; self.speaker = speaker; self.original = original
        self.translated = translated; self.isFinal = isFinal
        self.translationFailed = translationFailed
        self.translationProvisional = translationProvisional
    }
}
