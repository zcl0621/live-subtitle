import Foundation
import AVFoundation

/// 麦克风采集(=我)。**不开 VoiceProcessing**:实测(与社区一致,见 probes/RESULTS.md)VP 会把输入
/// 变多声道致静音、压低扬声器输出、还会掐 ScreenCaptureKit 的系统音轨,且并不能消掉别的 app 从扬声器
/// 放出来的对方声。外放漏音靠耳机兜底(通话推荐戴耳机)。
final class MicSource: NSObject, AudioSource, @unchecked Sendable {
    let track: Track = .mic
    var onError: (@Sendable (String) -> Void)?
    private let engine = AVAudioEngine()
    private let converter = FormatConverter()
    private var continuation: AsyncStream<AudioFrame>.Continuation?

    func frames() -> AsyncStream<AudioFrame> {
        AsyncStream(bufferingPolicy: .bufferingNewest(32)) { cont in
            self.continuation = cont
            self.start()
        }
    }

    private func start() {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self, let mono = FormatConverter.channelZeroMono(buf),
                  let samples = try? self.converter.convert(mono) else { return }
            self.continuation?.yield(AudioFrame(pcm: samples, track: .mic, hostTime: mach_absolute_time()))
        }
        engine.prepare()
        do { try engine.start() }
        catch {
            onError?("麦克风启动失败:\(error.localizedDescription) — 请在 系统设置→隐私与安全性→麦克风 授权 LiveSubtitle")
            continuation?.finish()
        }
    }

    func stop() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        continuation?.finish()
    }

}
