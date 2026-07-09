import Foundation
import AVFoundation

/// 麦克风采集(=我),开 VoiceProcessing 回声消除,消掉外放漏进来的对方声。
final class MicSource: NSObject, AudioSource, @unchecked Sendable {
    let speaker: Speaker = .me
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
        do {
            try input.setVoiceProcessingEnabled(true)   // 开 AEC
        } catch {
            onError?("回声消除启用失败:\(error.localizedDescription)(外放可能串音,建议戴耳机)")
        }
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self, let mono = Self.channelZeroMono(buf),
                  let samples = try? self.converter.convert(mono) else { return }
            self.continuation?.yield(AudioFrame(pcm: samples, speaker: .me, hostTime: mach_absolute_time()))
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

    /// 取 0 声道为单声道 buffer。VoiceProcessing 的输入是多声道(mic + 参考声道,数量还会变),
    /// 直接让 AVAudioConverter 下混整组声道会得到全静音;0 声道即 AEC 处理后的近端麦克风。
    private static func channelZeroMono(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let src = buf.floatChannelData,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: buf.format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: buf.frameLength) else { return nil }
        out.frameLength = buf.frameLength
        out.floatChannelData![0].update(from: src[0], count: Int(buf.frameLength))
        return out
    }
}
