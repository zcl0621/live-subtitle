// P5a 探针 — 双 SpeechAnalyzer/SpeechTranscriber 并发(M1 结构性 KILL 疑点)
// 两个识别器同时各喂一个文件(模拟"我轨"+"对方轨"),验能否并发、结果是否各自正确不串。
// 免权限(喂文件)。编译:swiftc -target arm64-apple-macos26.0 probes/p5a_dual_analyzer.swift -o /tmp/p5a && /tmp/p5a
import Foundation
import Speech
import AVFoundation

func runOne(tag: String, path: String) async -> (String, Int, Duration) {
    let t = SpeechTranscriber(locale: Locale(identifier: "en-US"),
                              transcriptionOptions: [], reportingOptions: [.volatileResults],
                              attributeOptions: [.audioTimeRange])
    _ = try? await AssetInventory.assetInstallationRequest(supporting: [t])?.downloadAndInstall()
    let a = SpeechAnalyzer(modules: [t])
    var finals = 0, text = ""
    let start = ContinuousClock.now
    let reader = Task {
        for try await r in t.results where r.isFinal { finals += 1; text += String(r.text.characters) }
    }
    do {
        let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        try await a.start(inputAudioFile: f, finishAfterFile: true)
        _ = try await reader.value
    } catch {
        return ("[\(tag)] 错误: \(error)", 0, .zero)
    }
    return (text, finals, ContinuousClock.now - start)
}

print("== P5a 探针:双 SpeechAnalyzer 并发 ==")

// —— 基线:单独各跑一次(顺序),记时间 ——
print("[1] 顺序基线:")
let (t1s, f1s, d1s) = await runOne(tag: "US-seq", path: "/tmp/real_us.wav")
let (t2s, f2s, d2s) = await runOne(tag: "UK-seq", path: "/tmp/real_uk.wav")
print("    US 顺序:\(f1s) 终句,\(d1s)")
print("    UK 顺序:\(f2s) 终句,\(d2s)")

// —— 并发:两个同时跑 ——
print("[2] 并发(两个 analyzer 同时):")
let cStart = ContinuousClock.now
async let r1 = runOne(tag: "US-par", path: "/tmp/real_us.wav")
async let r2 = runOne(tag: "UK-par", path: "/tmp/real_uk.wav")
let (t1, f1, d1) = await r1
let (t2, f2, d2) = await r2
let cTotal = ContinuousClock.now - cStart
print("    US 并发:\(f1) 终句,\(d1)")
print("    UK 并发:\(f2) 终句,\(d2)")
print("    并发总墙钟:\(cTotal)")

// —— 校验:并发结果是否与基线一致(不串轨/不掉句)——
print("[3] 校验:")
print("    US 并发文本 == 顺序文本 ? \(t1 == t1s)")
print("    UK 并发文本 == 顺序文本 ? \(t2 == t2s)")
print("    US 终句数 顺序\(f1s) vs 并发\(f1) ; UK 终句数 顺序\(f2s) vs 并发\(f2)")
print("    US 文本片段: \(t1.prefix(60))")
print("    UK 文本片段: \(t2.prefix(60))")
