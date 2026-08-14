// P7 探针 — SpeechTranscriber zh-CN 支持(KILL:不支持则 Task 7 中文会议作废)
// 验:1) supportedLocales 有无 zh 2) 中文模型 headless 下载 3) 中文识别抽样 + 终句滞后
// 编译:swiftc -target arm64-apple-macos26.0 probes/p7_zh_transcribe.swift -o /tmp/p7 && /tmp/p7 <中文音频>
import Foundation
import Speech
import AVFoundation

print("== P7 探针:SpeechTranscriber zh-CN ==")

// —— 1. supportedLocales 里有没有中文 ——
let supported = await SpeechTranscriber.supportedLocales
let ids = supported.map(\.identifier).sorted()
print("[1] supportedLocales(\(ids.count) 个):\(ids.joined(separator: " "))")
let zhCandidates = supported.filter { $0.identifier.lowercased().hasPrefix("zh") || $0.identifier.contains("Hans") || $0.identifier.contains("Hant") }
guard !zhCandidates.isEmpty else {
    print("[1] ❌ 无任何 zh/Hans/Hant locale → Task 7 作废,声纹侧不受影响")
    exit(2)
}
let zhLocale = zhCandidates.first { $0.identifier.contains("Hans") || $0.identifier.lowercased().contains("cn") } ?? zhCandidates[0]
print("[1] ✅ 中文候选:\(zhCandidates.map(\.identifier).joined(separator: " ")),选用 \(zhLocale.identifier)")

// —— 2. headless 安装中文模型 ——
let transcriber = SpeechTranscriber(
    locale: zhLocale,
    transcriptionOptions: [],
    reportingOptions: [.volatileResults, .fastResults],
    attributeOptions: [.audioTimeRange]
)
let status = await AssetInventory.status(forModules: [transcriber])
print("[2] AssetInventory.status(\(zhLocale.identifier)): \(status)")
if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    print("[2] 开始 headless downloadAndInstall() ...")
    let t0 = ContinuousClock.now
    try await req.downloadAndInstall()
    print("[2] ✅ 中文模型安装完成,耗时 \(ContinuousClock.now - t0)")
} else {
    print("[2] ✅ 无需安装(已就绪)")
}

// —— 3. 中文样本识别 + 终句滞后 ——
guard CommandLine.arguments.count > 1 else {
    print("[3] 未给音频参数,跳过识别抽样(Step 1/2 已可判定)")
    exit(0)
}
let url = URL(fileURLWithPath: CommandLine.arguments[1])
let analyzer = SpeechAnalyzer(modules: [transcriber])
let file = try AVAudioFile(forReading: url)
let clockStart = ContinuousClock.now
var finalText = ""
var volatileCount = 0, finalCount = 0
var firstFinalAt: Duration? = nil
var finalRanges: [String] = []

let reader = Task {
    for try await r in transcriber.results {
        let t = ContinuousClock.now - clockStart
        let s = String(r.text.characters)
        if r.isFinal {
            if firstFinalAt == nil { firstFinalAt = t }
            finalCount += 1
            finalText += s
            let range = r.range  // 非可选 CMTimeRange —— Task 6 直接用,无需从 attributed runs 挖
            finalRanges.append(String(format: "%.2f-%.2f", range.start.seconds, range.end.seconds))
            print("    [FINAL @\(t)] \(s)")
        } else {
            volatileCount += 1
        }
    }
}

print("[3] 喂入 \(String(format: "%.1f", Double(file.length)/file.fileFormat.sampleRate))s 中文音频 ...")
try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
_ = try await reader.value

print("\n[4] 汇总:")
print("    中间态 \(volatileCount) 条 / 终句 \(finalCount) 条,首终句 @ \(firstFinalAt.map{"\($0)"} ?? "无")")
print("    audioTimeRange(终句):\(finalRanges.joined(separator: "  "))")
print("    终句全文:\(finalText)")
print("    (识别准确率人工比对朗读文本;终句滞后与 P1b 英文 1.70s 中位对照需实时喂入,此处为批处理近似)")
