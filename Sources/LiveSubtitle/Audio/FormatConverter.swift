import AVFoundation

/// 任意输入 PCM → analyzer 目标格式(16kHz / Int16 / 单声道 交织)。
/// 每个输入源各建一个实例(AVAudioConverter 与源格式绑定)。
final class FormatConverter {
    let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                     sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    func convert(_ input: AVAudioPCMBuffer) throws -> [Int16] {
        if converter == nil || sourceFormat != input.format {
            guard let c = AVAudioConverter(from: input.format, to: targetFormat) else {
                throw ConvertError.cannotCreate
            }
            converter = c; sourceFormat = input.format
        }
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let cap = AVAudioFrameCount(Double(input.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: cap) else {
            throw ConvertError.cannotAllocate
        }
        var fed = false
        var err: NSError?
        // 每个输入 buffer 当作一段独立完整流:上一次 .endOfStream 会让转换器停在终态,
        // 不 reset 则后续 buffer 立即返回 .endOfStream / 0 帧(只有首个 buffer 出声)。
        converter!.reset()
        converter!.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true; status.pointee = .haveData; return input
        }
        if let err { throw err }
        let n = Int(out.frameLength)
        guard let src = out.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: src[0], count: n))
    }

    enum ConvertError: Error { case cannotCreate, cannotAllocate }

    /// 取 0 声道为单声道 buffer(兜底任意声道数;AVAudioEngine 输入节点通常是 Float32 非交织)。
    /// 不显式取 0 声道直接丢给 AVAudioConverter 的话,多声道输入会转出静音
    /// —— 麦克风采集与设置页录声纹两条路径共用这一手,别只在其中一处修。
    static func channelZeroMono(_ buf: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let src = buf.floatChannelData,
              let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: buf.format.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: buf.frameLength) else { return nil }
        out.frameLength = buf.frameLength
        out.floatChannelData![0].update(from: src[0], count: Int(buf.frameLength))
        return out
    }
}
