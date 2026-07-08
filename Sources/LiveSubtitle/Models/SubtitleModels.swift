import Foundation

enum Speaker: Sendable, Equatable { case me, other }        // 麦克风=me,系统声=other
enum DisplayMode: Sendable { case originalOnly, both, translatedOnly }
enum OverlayMode: Sendable { case bar, mini }

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

    init(id: UUID = UUID(), speaker: Speaker, original: String,
         translated: String? = nil, isFinal: Bool = false) {
        self.id = id; self.speaker = speaker; self.original = original
        self.translated = translated; self.isFinal = isFinal
    }
}
