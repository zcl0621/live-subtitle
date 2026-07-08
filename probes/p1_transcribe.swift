// P1 探针 — SpeechAnalyzer / SpeechTranscriber(macOS 26)冒烟测
// 验:1) headless 下 en-US 模型(AssetInventory) 2) 能否识别 3) 中间态/终句机制 4) 处理速度
// 注:喂文件=批处理,测"处理时间"非实时首字延迟;say 合成音=干净美音,非口音鲁棒性测。
// 编译:swiftc -target arm64-apple-macos26.0 probes/p1_transcribe.swift -o /tmp/p1 && /tmp/p1 <aiff>
import Foundation
import Speech
import AVFoundation

let audioPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/p1_sample.aiff"
let url = URL(fileURLWithPath: audioPath)

print("== P1 探针:SpeechTranscriber 冒烟测 ==")
print("音频:\(audioPath)")

let locale = Locale(identifier: "en-US")
let transcriber = SpeechTranscriber(
    locale: locale,
    transcriptionOptions: [],
    reportingOptions: [.volatileResults],
    attributeOptions: [.audioTimeRange]
)

// —— 1. 模型资产状态 + headless 安装 ——
let assetStatus = await AssetInventory.status(forModules: [transcriber])
print("[1] AssetInventory.status(en-US transcriber): \(assetStatus)")
if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
    print("[1b] 需要安装模型,开始 headless downloadAndInstall() ...")
    let t0 = ContinuousClock.now
    try await req.downloadAndInstall()
    print("[1b] 模型安装完成,耗时 \(ContinuousClock.now - t0)")
} else {
    print("[1b] 无需安装(模型已就绪或无请求)")
}

// —— 2. 建 analyzer,并发读结果 ——
let analyzer = SpeechAnalyzer(modules: [transcriber])
let file = try AVAudioFile(forReading: url)
let clockStart = ContinuousClock.now
var firstVolatileAt: Duration? = nil
var firstFinalAt: Duration? = nil
var finalText = ""
var volatileCount = 0, finalCount = 0

let reader = Task {
    for try await r in transcriber.results {
        let t = ContinuousClock.now - clockStart
        let s = String(r.text.characters)
        if r.isFinal {
            if firstFinalAt == nil { firstFinalAt = t }
            finalCount += 1
            finalText += s
            print("    [FINAL  @\(t)] \(s)")
        } else {
            if firstVolatileAt == nil { firstVolatileAt = t }
            volatileCount += 1
            print("    [volatile @\(t)] \(s)")
        }
    }
}

// —— 3. 喂文件(批处理),结束后收尾 ——
print("[2] start(inputAudioFile:finishAfterFile:true) 喂入 \(String(format: "%.1f", Double(file.length)/file.fileFormat.sampleRate))s 音频 ...")
try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
_ = try await reader.value

// —— 4. 汇总 ——
let total = ContinuousClock.now - clockStart
print("\n[3] 汇总:")
print("    首个中间态 @ \(firstVolatileAt.map{"\($0)"} ?? "无")")
print("    首个终句   @ \(firstFinalAt.map{"\($0)"} ?? "无")")
print("    中间态条数 \(volatileCount) / 终句条数 \(finalCount)")
print("    全程处理耗时 \(total)(注:批处理,非实时延迟)")
print("    终句全文:\(finalText)")
