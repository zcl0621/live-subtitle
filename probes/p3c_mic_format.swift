// P3c 探针 — FormatConverter 的转换逻辑能否处理麦克风(VP)的 24k/3ch/Float32
// 对比:对方轨 48k/2ch(已知工作) vs 我轨 24k/3ch(疑似失败)
// 复刻 FormatConverter.convert 的核心:建 AVAudioConverter + 单次 endOfStream 转换
// 编译:swiftc -target arm64-apple-macos26.0 probes/p3c_mic_format.swift -o /tmp/p3c && /tmp/p3c
import AVFoundation

let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true)!

func tryConvert(_ label: String, sr: Double, ch: AVAudioChannelCount, interleaved: Bool) {
    print("\n== \(label): \(Int(sr))Hz \(ch)ch Float32 interleaved=\(interleaved) → 16k/Int16/mono ==")
    guard let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: ch, interleaved: interleaved) else {
        print("  ❌ 源格式建不出来"); return
    }
    guard let conv = AVAudioConverter(from: src, to: target) else {
        print("  ❌ AVAudioConverter(from:to:) == nil —— 这个格式对不支持转换(=麦克风轨一帧都产不出)"); return
    }
    print("  ✅ converter 建立成功")
    let n = Int(sr) // 1s
    guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(n)) else { print("  ❌ 输入 buffer 建不出来"); return }
    inBuf.frameLength = AVAudioFrameCount(n)
    // 填正弦(交织/非交织都填 ch0 附近即可)
    if interleaved {
        let p = inBuf.floatChannelData![0]
        for i in 0..<(n * Int(ch)) { p[i] = sin(Float(i) * 0.05) * 0.5 }
    } else {
        for c in 0..<Int(ch) { let p = inBuf.floatChannelData![c]; for i in 0..<n { p[i] = sin(Float(i) * 0.05) * 0.5 } }
    }
    let outCap = AVAudioFrameCount(Double(n) * target.sampleRate / sr) + 1024
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outCap) else { print("  ❌ 输出 buffer 建不出来"); return }
    var fed = false; var err: NSError?
    conv.convert(to: out, error: &err) { _, s in if fed { s.pointee = .endOfStream; return nil }; fed = true; s.pointee = .haveData; return inBuf }
    if let err { print("  ❌ convert 抛错: \(err)"); return }
    print("  ✅ 转换成功,输出 \(out.frameLength) 帧(≈\(Double(out.frameLength)/16000)s)")
}

print("== P3c:FormatConverter 对麦克风格式的适配 ==")
// 对方轨(已知工作)
tryConvert("对方轨 48k/2ch 非交织", sr: 48000, ch: 2, interleaved: false)
// 我轨候选(Phase 0 实测 24k/3ch/Float32,交织性未定,两种都试)
tryConvert("我轨 24k/3ch 非交织", sr: 24000, ch: 3, interleaved: false)
tryConvert("我轨 24k/3ch 交织", sr: 24000, ch: 3, interleaved: true)
// 兜底候选:单声道
tryConvert("我轨 24k/1ch 非交织", sr: 24000, ch: 1, interleaved: false)
