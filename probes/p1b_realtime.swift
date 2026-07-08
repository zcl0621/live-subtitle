// P1b 探针 — SpeechTranscriber 实时流式喂入,测真实字幕滞后
// 按 1× 实时节奏喂 buffer;lag = 结果到达墙钟 - result.range.end(音频时间轴)
// = "说完到字幕出现"的滞后。这才是真实时延迟(P1 的批处理版不算)。
// 编译:swiftc -target arm64-apple-macos26.0 probes/p1b_realtime.swift -o /tmp/p1b && /tmp/p1b <wav>
import Foundation
import Speech
import AVFoundation

let audioPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/real_us.wav"
let url = URL(fileURLWithPath: audioPath)
print("== P1b 探针:实时流式,测字幕滞后 ==\n音频:\(audioPath)")

let transcriber = SpeechTranscriber(
    locale: Locale(identifier: "en-US"),
    transcriptionOptions: [],
    reportingOptions: [.volatileResults, .fastResults],   // ← 加 .fastResults 测能否压低终句滞后
    attributeOptions: [.audioTimeRange]
)
_ = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])?.downloadAndInstall()

guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
    print("无可用格式"); exit(1)
}
print("analyzer 目标格式:\(fmt.sampleRate)Hz, \(fmt.channelCount)ch, common=\(fmt.commonFormat.rawValue), interleaved=\(fmt.isInterleaved)")

// —— 读整文件并一次性转换到 analyzer 格式 ——
let inFile = try AVAudioFile(forReading: url)
let inFmt = inFile.processingFormat
guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: AVAudioFrameCount(inFile.length)) else { exit(1) }
try inFile.read(into: inBuf)
guard let conv = AVAudioConverter(from: inFmt, to: fmt) else { print("无法建转换器"); exit(1) }
let ratio = fmt.sampleRate / inFmt.sampleRate
let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * ratio) + 4096
guard let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: outCap) else { exit(1) }
var fed = false
var err: NSError?
conv.convert(to: outBuf, error: &err) { _, status in
    if fed { status.pointee = .endOfStream; return nil }
    fed = true; status.pointee = .haveData; return inBuf
}
if let err { print("转换错误:\(err)"); exit(1) }
let totalFrames = Int(outBuf.frameLength)
let audioSeconds = Double(totalFrames) / fmt.sampleRate
print("转换后:\(totalFrames) 帧 ≈ \(String(format: "%.1f", audioSeconds))s")

// —— 切成 0.1s 块,建实时输入流(analyzer 格式为 Int16 交织) ——
let chunk = Int(fmt.sampleRate * 0.1)
guard let src = outBuf.int16ChannelData else { print("非 Int16 格式,需再适配"); exit(1) }
let ch = Int(fmt.channelCount)   // 交织:src[0] 连续存 frameLength*ch 个样本

let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
let analyzer = SpeechAnalyzer(modules: [transcriber])

let clockStart = ContinuousClock.now
func elapsed() -> Double { Double((ContinuousClock.now - clockStart).components.attoseconds) / 1e18 + Double((ContinuousClock.now - clockStart).components.seconds) }

var firstVolatileLag: Double? = nil
var finalLags: [Double] = []
let reader = Task {
    for try await r in transcriber.results {
        let arr = elapsed()
        let audioEnd = r.range.end.seconds                      // 该结果覆盖到的音频时刻
        let lag = arr - audioEnd                                 // 墙钟已到 vs 音频进度 = 滞后
        if r.isFinal {
            finalLags.append(lag)
            print(String(format: "  [FINAL 滞后 %.3fs] %@", lag, String(r.text.characters)))
        } else if firstVolatileLag == nil {
            firstVolatileLag = lag
        }
    }
}

try await analyzer.start(inputSequence: stream)
// —— 实时节奏喂块 ——
var pos = 0
while pos < totalFrames {
    let n = min(chunk, totalFrames - pos)
    guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n)) else { break }
    b.frameLength = AVAudioFrameCount(n)
    // 交织 Int16:整块连续拷贝 n*ch 个样本
    b.int16ChannelData![0].update(from: src[0] + pos * ch, count: n * ch)
    cont.yield(AnalyzerInput(buffer: b))
    pos += n
    try? await Task.sleep(for: .milliseconds(100))              // 1× 实时
}
cont.finish()
try await analyzer.finalizeAndFinishThroughEndOfInput()
_ = try await reader.value

let med = finalLags.sorted()
print("\n[汇总] 实时字幕滞后(说完→显示):")
print(String(format: "  首个中间态滞后 %@", firstVolatileLag.map{String(format:"%.3fs",$0)} ?? "无"))
if !med.isEmpty {
    print(String(format: "  终句滞后 min %.3fs / 中位 %.3fs / max %.3fs(共 %d 句)",
                 med.first!, med[med.count/2], med.last!, med.count))
}
