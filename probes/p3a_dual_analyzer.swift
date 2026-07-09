// P3a 探针 — 两个 SpeechAnalyzer 是否能并发各出结果(Phase 2 双轨前提)
// 编译:swiftc -target arm64-apple-macos26.0 probes/p3a_dual_analyzer.swift -o /tmp/p3a && /tmp/p3a <wavA> <wavB>
import Foundation
import Speech
import AVFoundation

func makeStack() -> (SpeechAnalyzer, SpeechTranscriber) {
    let t = SpeechTranscriber(locale: Locale(identifier: "en-US"),
        transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
        attributeOptions: [.audioTimeRange])
    return (SpeechAnalyzer(modules: [t]), t)
}

// 把整段 wav 转成 analyzer 格式,按 1× 实时喂,统计终句数
func feed(label: String, wav: String, analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber) async -> Int {
    let url = URL(fileURLWithPath: wav)
    guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        print("  [\(label)] 无可用格式"); return -1
    }
    guard let inFile = try? AVAudioFile(forReading: url),
          let inBuf = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat, frameCapacity: AVAudioFrameCount(inFile.length)),
          (try? inFile.read(into: inBuf)) != nil,
          let conv = AVAudioConverter(from: inFile.processingFormat, to: fmt) else {
        print("  [\(label)] 读取/转换器建立失败"); return -1
    }
    let outCap = AVAudioFrameCount(Double(inBuf.frameLength) * fmt.sampleRate / inFile.processingFormat.sampleRate) + 4096
    let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: outCap)!
    var fed = false
    conv.convert(to: outBuf, error: nil) { _, s in if fed { s.pointee = .endOfStream; return nil }; fed = true; s.pointee = .haveData; return inBuf }

    let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
    var finals = 0
    let reader = Task {
        for try await r in transcriber.results where r.isFinal {
            finals += 1; print("  [\(label) FINAL] \(String(r.text.characters))")
        }
    }
    do { try await analyzer.start(inputSequence: stream) } catch { print("  [\(label)] analyzer.start 抛错: \(error)"); return -1 }
    let total = Int(outBuf.frameLength); let chunk = Int(fmt.sampleRate * 0.1)
    let src = outBuf.int16ChannelData![0]; let ch = Int(fmt.channelCount); var pos = 0
    while pos < total {
        let n = min(chunk, total - pos)
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!
        b.frameLength = AVAudioFrameCount(n)
        b.int16ChannelData![0].update(from: src + pos * ch, count: n * ch)
        cont.yield(AnalyzerInput(buffer: b)); pos += n
        try? await Task.sleep(for: .milliseconds(100))
    }
    cont.finish()
    try? await analyzer.finalizeAndFinishThroughEndOfInput()
    _ = try? await reader.value
    return finals
}

let a = CommandLine.arguments
let wavA = a.count > 1 ? a[1] : "/tmp/real_us.wav"
let wavB = a.count > 2 ? a[2] : "/tmp/real_uk.wav"
print("== P3a:两个 SpeechAnalyzer 并发 ==\nA=\(wavA)\nB=\(wavB)")
let (an1, tr1) = makeStack(); let (an2, tr2) = makeStack()
_ = try? await AssetInventory.assetInstallationRequest(supporting: [tr1])?.downloadAndInstall()

let t0 = ContinuousClock.now
async let f1 = feed(label: "A", wav: wavA, analyzer: an1, transcriber: tr1)
async let f2 = feed(label: "B", wav: wavB, analyzer: an2, transcriber: tr2)
let (n1, n2) = await (f1, f2)
print("\n[结果] A 终句=\(n1)  B 终句=\(n2)  并发耗时=\(ContinuousClock.now - t0)")
print(n1 > 0 && n2 > 0 ? "✅ GO:两个分析器并发都出结果" : "❌ NO-GO:并发失败,回设计")
