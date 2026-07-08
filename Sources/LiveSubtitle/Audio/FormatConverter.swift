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
}
