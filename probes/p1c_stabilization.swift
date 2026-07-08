// P1c 探针 — 量"终句定稿延迟"里有多少是白等
// 对每个 final,找最早 text 完全一致的 volatile 出现时刻;gap = final盖章 - volatile稳定 = 可省回的延迟
// 编译:swiftc -target arm64-apple-macos26.0 probes/p1c_stabilization.swift -o /tmp/p1c && /tmp/p1c <wav>
import Foundation
import Speech
import AVFoundation

let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/real_us.wav"
print("== P1c:终句定稿延迟拆解 ==\n音频:\(path)")

let t = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                          transcriptionOptions: [], reportingOptions: [.volatileResults],
                          attributeOptions: [.audioTimeRange])
_ = try? await AssetInventory.assetInstallationRequest(supporting: [t])?.downloadAndInstall()
guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else { exit(1) }

// 转换到 analyzer 格式(16k Int16)
let inFile = try AVAudioFile(forReading: URL(fileURLWithPath: path))
let inBuf = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat, frameCapacity: AVAudioFrameCount(inFile.length))!
try inFile.read(into: inBuf)
let conv = AVAudioConverter(from: inFile.processingFormat, to: fmt)!
let outBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(Double(inBuf.frameLength) * fmt.sampleRate/inFile.processingFormat.sampleRate) + 4096)!
var fed = false; var e: NSError?
conv.convert(to: outBuf, error: &e) { _, s in if fed { s.pointee = .endOfStream; return nil }; fed = true; s.pointee = .haveData; return inBuf }
let total = Int(outBuf.frameLength); let src = outBuf.int16ChannelData![0]; let ch = Int(fmt.channelCount)

func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
struct Ev { let at: Double; let final: Bool; let text: String; let endT: Double }
var evs: [Ev] = []
let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
let a = SpeechAnalyzer(modules: [t])
let start = ContinuousClock.now
func el() -> Double { let d = ContinuousClock.now - start; return Double(d.components.seconds) + Double(d.components.attoseconds)/1e18 }

let reader = Task {
    for try await r in t.results {
        evs.append(Ev(at: el(), final: r.isFinal, text: String(r.text.characters), endT: r.range.end.seconds))
    }
}
try await a.start(inputSequence: stream)
let chunk = Int(fmt.sampleRate * 0.1); var pos = 0
while pos < total {
    let n = min(chunk, total - pos)
    let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!; b.frameLength = AVAudioFrameCount(n)
    b.int16ChannelData![0].update(from: src + pos*ch, count: n*ch)
    cont.yield(AnalyzerInput(buffer: b)); pos += n
    try? await Task.sleep(for: .milliseconds(100))
}
cont.finish(); try await a.finalizeAndFinishThroughEndOfInput(); _ = try await reader.value

// 对每个 final,找最早"归一化文本一致"的 volatile
func f2(_ x: Double) -> String { String(format: "%.2f", x) }
print("\n每句:[final盖章s | volatile稳定s | 白等s] 文本")
var saved: [Double] = []
for f in evs where f.final {
    let key = norm(f.text)
    let stable = evs.first(where: { !$0.final && norm($0.text) == key })?.at
    let snippet = String(f.text.prefix(45))
    if let st = stable {
        let gap = f.at - st; saved.append(gap)
        print("  [\(f2(f.at)) | \(f2(st)) | 省\(f2(gap))]  \(snippet)")
    } else {
        print("  [\(f2(f.at)) |   -   | 无一致volatile]  \(snippet)")
    }
}
if !saved.isEmpty {
    let s = saved.sorted()
    print("\n白等(盖章 - 稳定)中位 \(f2(s[s.count/2]))s / max \(f2(s.last!))s")
    print("→ 若在稳定 volatile 上就翻译,约能省这么多延迟")
}
