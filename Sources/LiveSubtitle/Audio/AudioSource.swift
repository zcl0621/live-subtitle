import Foundation

/// 一条音频输入轨。类约束(存在型需可设 onError)。
/// Sendable:两个具体轨(SystemAudioSource/MicSource)已各自声明 @unchecked Sendable,
/// 这里在协议上显式标注,让 `any AudioSource` 存在型也可跨隔离域调用 async stop()。
protocol AudioSource: AnyObject, Sendable {
    var speaker: Speaker { get }
    var onError: (@Sendable (String) -> Void)? { get set }
    func frames() -> AsyncStream<AudioFrame>
    func stop() async
}
