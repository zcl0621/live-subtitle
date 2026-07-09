import Foundation

/// 一条音频输入轨。类约束(存在型需可设 onError)。
protocol AudioSource: AnyObject {
    var speaker: Speaker { get }
    var onError: (@Sendable (String) -> Void)? { get set }
    func frames() -> AsyncStream<AudioFrame>
    func stop() async
}
