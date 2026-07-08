import Foundation

/// 一条带来源标的音频轨:产出已转换到 analyzer 格式的 AudioFrame 流。
protocol AudioSource {
    var speaker: Speaker { get }
    func frames() -> AsyncStream<AudioFrame>
    func stop() async
}
