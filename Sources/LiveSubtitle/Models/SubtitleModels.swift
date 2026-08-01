import Foundation

enum Speaker: Sendable, Equatable { case me, other }        // 麦克风=me,系统声=other
enum DisplayMode: String, Sendable, CaseIterable { case originalOnly, both, translatedOnly }
enum OverlayMode: String, Sendable, CaseIterable { case bar, mini }

extension DisplayMode {
    var showsOriginal: Bool { self != .translatedOnly }
    var showsTranslated: Bool { self != .originalOnly }
}

/// 跨 actor 的 Sendable 音频载体(不直接传 AVAudioPCMBuffer,后者非 Sendable)。
/// pcm 为已转换到 analyzer 目标格式(16k/Int16/单声道)的样本。
struct AudioFrame: Sendable {
    let pcm: [Int16]
    let speaker: Speaker
    let hostTime: UInt64
}

struct SubtitleLine: Identifiable, Sendable {
    let id: UUID
    let speaker: Speaker
    var original: String
    var translated: String?
    var isFinal: Bool
    /// 翻译已尝试但失败(区别于「尚未翻译/翻译中」)。UI 据此回退显原文而非永久「翻译中…」。
    var translationFailed: Bool
    /// 当前 translated 来自中间态的半句译文(临时)。终句成句译文到位前为 true;
    /// 若终句重译失败,这份半句译文不可当作定稿译文,应回退显原文。
    var translationProvisional: Bool

    init(id: UUID = UUID(), speaker: Speaker, original: String,
         translated: String? = nil, isFinal: Bool = false,
         translationFailed: Bool = false, translationProvisional: Bool = false) {
        self.id = id; self.speaker = speaker; self.original = original
        self.translated = translated; self.isFinal = isFinal
        self.translationFailed = translationFailed
        self.translationProvisional = translationProvisional
    }
}
