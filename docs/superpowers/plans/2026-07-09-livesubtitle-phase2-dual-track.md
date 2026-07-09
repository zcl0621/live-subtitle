# LiveSubtitle Phase 2 — 双轨(我 + 对方)Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Phase 1(对方单轨,已端到端通过)基础上加入麦克风轨(我),实现双向字幕:对方英文→中文(橙)+ 我英文→中文(蓝),两轨并行、双色、中间态防闪烁。全本地无云。

**Architecture:** `CaptionEngine` 从单轨泛化为双轨。新增 `MicSource`(`AVAudioEngine` + VoiceProcessing 回声消除,`speaker=.me`),与 Phase 1 的 `SystemAudioSource`(`.other`)并行,各接一条独立 `TranscriptionPipeline`(en→zh),结果按说话人打标写入同一 `@MainActor @Observable SubtitleStore`,`SubtitleBarView` 双色渲染。volatile 中间态经节流(coalesce)再上屏。

**Tech Stack:** Swift 6 · macOS 26 SDK · **SwiftPM**(承接 Phase 1)· AVAudioEngine + VoiceProcessing · Speech(SpeechAnalyzer×2)· Translation · ScreenCaptureKit · SwiftUI/AppKit · XCTest。

> **构建/命令(承接 Phase 1):** `swift build` / `swift test --filter X` / 运行 GUI:`bash scripts/build-app.sh && open build/LiveSubtitle.app`。源码 `Sources/LiveSubtitle/<Group>/*.swift`,测试 `Tests/LiveSubtitleTests/*.swift`,探针 `probes/*.swift`(`swiftc -target arm64-apple-macos26.0`)。

> **⚠️ 探针门(Task 0)是 go/no-go 关卡。** Task 0 未通过前**不得**开始 Task 1+。若 Task 0 任一子探针失败 → STOP,回设计重议(见 spec 的失败预案),不硬凑。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `probes/p3a_dual_analyzer.swift` | 验两个 SpeechAnalyzer 并发出结果 | Create |
| `probes/p3b_vp_aec.swift` | 验 VoiceProcessing AEC 消对方漏音 | Create |
| `probes/RESULTS.md` | 记 P3 go/no-go | Modify |
| `Sources/LiveSubtitle/Audio/AudioSource.swift` | 协议加 `onError`,类约束 | Modify |
| `Sources/LiveSubtitle/Audio/MicSource.swift` | 麦克风采集 + VP(AEC),`.me` 轨 | Create |
| `Sources/LiveSubtitle/Models/SubtitleStore.swift` | volatile 暂存 + flush(防闪烁) | Modify |
| `Sources/LiveSubtitle/Pipeline/CaptionEngine.swift` | 双轨泛化 + 节流 flush task | Modify |
| `Tests/LiveSubtitleTests/SubtitleStoreTests.swift` | 补 stage/flush 测试 | Modify |
| `Tests/LiveSubtitleTests/CaptionEngineTests.swift` | 双轨 wiring(假 source) | Create |

---

## Task 0: P3 探针(go/no-go,先行)

**Files:**
- Create: `probes/p3a_dual_analyzer.swift`, `probes/p3b_vp_aec.swift`
- Modify: `probes/RESULTS.md`

**说明:** 探针是 spike,不走 TDD。P3a 可 headless 跑(两个 wav,无需授权),P3b 需真机(麦克风 + 外放 + 用户在场且不说话)。

- [ ] **Step 1: 写 P3a — 两个 SpeechAnalyzer 并发**

`probes/p3a_dual_analyzer.swift`:

```swift
// P3a 探针 — 两个 SpeechAnalyzer 是否能并发各出结果
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

// 把整段 wav 转成 analyzer 格式并 1× 实时喂,统计终句数
func feed(label: String, wav: String, analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber) async -> Int {
    let url = URL(fileURLWithPath: wav)
    guard let fmt = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { return -1 }
    let inFile = try! AVAudioFile(forReading: url)
    let inBuf = AVAudioPCMBuffer(pcmFormat: inFile.processingFormat, frameCapacity: AVAudioFrameCount(inFile.length))!
    try! inFile.read(into: inBuf)
    let conv = AVAudioConverter(from: inFile.processingFormat, to: fmt)!
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
    try! await analyzer.start(inputSequence: stream)
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
    try! await analyzer.finalizeAndFinishThroughEndOfInput()
    _ = try? await reader.value
    return finals
}

let a = CommandLine.arguments
let wavA = a.count > 1 ? a[1] : "/tmp/real_us.wav"
let wavB = a.count > 2 ? a[2] : "/tmp/real_us.wav"
print("== P3a:两个 SpeechAnalyzer 并发 ==")
let (an1, tr1) = makeStack(); let (an2, tr2) = makeStack()
_ = try? await AssetInventory.assetInstallationRequest(supporting: [tr1])?.downloadAndInstall()

let t0 = ContinuousClock.now
async let f1 = feed(label: "A", wav: wavA, analyzer: an1, transcriber: tr1)
async let f2 = feed(label: "B", wav: wavB, analyzer: an2, transcriber: tr2)
let (n1, n2) = await (f1, f2)
print("[结果] A 终句=\(n1)  B 终句=\(n2)  并发耗时=\(ContinuousClock.now - t0)")
print(n1 > 0 && n2 > 0 ? "✅ GO:两个分析器并发都出结果" : "❌ NO-GO:并发失败,回设计")
```

- [ ] **Step 2: 跑 P3a**

Run: `swiftc -target arm64-apple-macos26.0 probes/p3a_dual_analyzer.swift -o /tmp/p3a && /tmp/p3a /tmp/real_us.wav /tmp/real_us.wav`
Expected(GO):两路都打印 FINAL 且末行 `✅ GO`。若无 wav,先用任意英文 wav 放 `/tmp/real_us.wav`。

- [ ] **Step 3: 写 P3b — VoiceProcessing AEC 消对方漏音**

`probes/p3b_vp_aec.swift`:

```swift
// P3b 探针 — 外放对方音频时,VP 开启的麦克风轨是否"听不到"对方(AEC 生效)
// 需真机:外放扬声器 + 麦克风授权 + 用户在场且全程不说话
// 步骤:先跑本探针(它开麦克风+VP并识别),另开一终端 afplay 一段英文;
//       若麦克风轨几乎不出该英文的识别结果 → AEC 生效。
// 编译:swiftc -target arm64-apple-macos26.0 probes/p3b_vp_aec.swift -o /tmp/p3b && /tmp/p3b
import Foundation
import Speech
import AVFoundation

print("== P3b:VoiceProcessing AEC ==")
print("请:1) 保持外放 2) 本进程启动后,另开终端跑 `afplay 一段英文.wav` 3) 全程别自己说话")

let engine = AVAudioEngine()
let input = engine.inputNode
do { try input.setVoiceProcessingEnabled(true); print("VP 已启用") }
catch { print("VP 启用失败:\(error)"); exit(1) }

let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"),
    transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
    attributeOptions: [.audioTimeRange])
_ = try? await AssetInventory.assetInstallationRequest(supporting: [transcriber])?.downloadAndInstall()
guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { exit(1) }
let analyzer = SpeechAnalyzer(modules: [transcriber])
let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()

let fmt = input.outputFormat(forBus: 0)
print("麦克风(VP)格式:\(fmt.sampleRate)Hz \(fmt.channelCount)ch common=\(fmt.commonFormat.rawValue) interleaved=\(fmt.isInterleaved)")
let conv = AVAudioConverter(from: fmt, to: target)!
input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buf, _ in
    let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / fmt.sampleRate) + 1024
    let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap)!
    var fed = false
    conv.convert(to: out, error: nil) { _, s in if fed { s.pointee = .endOfStream; return nil }; fed = true; s.pointee = .haveData; return buf }
    cont.yield(AnalyzerInput(buffer: out))
}
var micFinals: [String] = []
let reader = Task { for try await r in transcriber.results where r.isFinal { let s = String(r.text.characters); micFinals.append(s); print("  [麦克风轨 FINAL] \(s)") } }
try await analyzer.start(inputSequence: stream)
engine.prepare(); try engine.start()
print("采集中… 20 秒后自动停。现在去另一个终端 afplay 英文。")
try await Task.sleep(for: .seconds(20))
input.removeTap(onBus: 0); engine.stop(); cont.finish()
try await analyzer.finalizeAndFinishThroughEndOfInput(); _ = try? await reader.value
print("[结果] 麦克风轨在你没说话时收到 \(micFinals.count) 条终句。")
print(micFinals.isEmpty ? "✅ GO:AEC 生效(对方漏音被消)" : "⚠️ 检查:麦克风轨仍收到内容,可能 AEC 不足或环境噪声,需人工判断上面几句是不是 afplay 的对方英文")
```

- [ ] **Step 4: 跑 P3b(真机,用户执行)**

Run(终端1):`swiftc -target arm64-apple-macos26.0 probes/p3b_vp_aec.swift -o /tmp/p3b && /tmp/p3b`
Run(终端2,启动后):`afplay <一段英文.wav>`(或系统朗读:`say -o /tmp/en.aiff "the quarterly revenue was up seventeen percent"; afplay /tmp/en.aiff`)
Expected(GO):你不说话时麦克风轨几乎不出 afplay 的英文 → `✅ GO`。若大量出现 afplay 的原句 → AEC 不足,按 spec 失败预案(耳机兜底/能量门限)。

- [ ] **Step 5: 记录 go/no-go 到 `probes/RESULTS.md`**

在 `probes/RESULTS.md` 加 "P3 双轨探针" 小节:P3a 两分析器并发结果 + P3b AEC 结论 + VP 实测格式(sampleRate/ch/interleaved,供 Task 1 用)+ 最终 GO/NO-GO。

- [ ] **Step 6: Commit**

```bash
git add probes/p3a_dual_analyzer.swift probes/p3b_vp_aec.swift probes/RESULTS.md
git commit -m "probe: P3 dual-analyzer concurrency + VoiceProcessing AEC (go/no-go)"
```

> **GATE:** P3a=GO 且 P3b=GO(或已定耳机兜底)才继续。否则 STOP,回 spec 重议。

---

## Task 1: MicSource(麦克风 + VoiceProcessing AEC)

**Files:**
- Modify: `Sources/LiveSubtitle/Audio/AudioSource.swift`
- Create: `Sources/LiveSubtitle/Audio/MicSource.swift`

**依赖 P3b 记录的 VP 实测格式与声道语义**(3ch 时哪个是干净麦克风)。以下按 Phase 0 实测 24k/3ch/Float32 写,若 P3b 结果不同则据实调整 tap/转换。

- [ ] **Step 1: AudioSource 协议加 `onError` 并类约束**

改 `AudioSource.swift`:

```swift
import Foundation

/// 一条音频输入轨。类约束(存在型需可设 onError)。
protocol AudioSource: AnyObject {
    var speaker: Speaker { get }
    var onError: (@Sendable (String) -> Void)? { get set }
    func frames() -> AsyncStream<AudioFrame>
    func stop() async
}
```

`SystemAudioSource` 已有 `onError` 属性,加 `AnyObject` 约束后自动满足(它是 final class)。确认 `SystemAudioSource` 声明的 `var onError` 与协议一致(已是)。

- [ ] **Step 2: 写 MicSource**

`Sources/LiveSubtitle/Audio/MicSource.swift`:

```swift
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
        let format = input.outputFormat(forBus: 0)      // VP 下实测 24k/3ch/Float32(以 P3b 记录为准)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self, let samples = try? self.converter.convert(buf) else { return }
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
}
```

> **注:** `FormatConverter` 需能把 24k/3ch/Float32 降到 16k/Int16/mono。`AVAudioConverter` 支持声道下混;若 P3b 显示 3ch 中只有 ch0 是干净麦克风,则在 Task 1 里给 tap 传一个单声道 desired format 或在转换前取 ch0。实现时以 P3b 记录为准,必要时补一个针对多声道输入的 `FormatConverter` 测试。

- [ ] **Step 3: 编译验证**

Run: `swift build`
Expected: `Build complete!`(MicSource 无法纯单测采集,靠 Task 5 真机验证。)

- [ ] **Step 4: Commit**

```bash
git add Sources/LiveSubtitle/Audio/AudioSource.swift Sources/LiveSubtitle/Audio/MicSource.swift
git commit -m "feat: add MicSource (AVAudioEngine + VoiceProcessing AEC), .me track"
```

---

## Task 2: SubtitleStore volatile 暂存 + flush(防闪烁基础)

**Files:**
- Modify: `Sources/LiveSubtitle/Models/SubtitleStore.swift`
- Modify: `Tests/LiveSubtitleTests/SubtitleStoreTests.swift`

**思路:** volatile 更新先进"暂存区"(不动 UI),由节流器定时 `flushVolatile()` 一次性上屏。commitFinal 时清掉该说话人暂存,避免陈旧 volatile 盖在 final 后面。

- [ ] **Step 1: 写失败测试**

加到 `SubtitleStoreTests.swift`:

```swift
func testStageVolatileDoesNotShowUntilFlush() {
    let s = SubtitleStore()
    s.stageVolatile(speaker: .other, text: "hel")
    s.stageVolatile(speaker: .other, text: "hello wor")
    XCTAssertTrue(s.lines.isEmpty)          // 未 flush 前不上屏
    s.flushVolatile()
    XCTAssertEqual(s.lines.count, 1)
    XCTAssertEqual(s.lines[0].original, "hello wor")   // 合并:只留最后一次
}

func testFlushAppliesBothSpeakers() {
    let s = SubtitleStore()
    s.stageVolatile(speaker: .other, text: "hi there")
    s.stageVolatile(speaker: .me, text: "yes ok")
    s.flushVolatile()
    XCTAssertEqual(Set(s.lines.map(\.speaker)), [.other, .me])
}

func testCommitFinalClearsStagedVolatileForSpeaker() {
    let s = SubtitleStore()
    s.stageVolatile(speaker: .other, text: "stale")
    _ = s.commitFinal(speaker: .other, text: "final text")
    s.flushVolatile()                        // 陈旧 volatile 不应再造一行
    XCTAssertEqual(s.lines.count, 1)
    XCTAssertEqual(s.lines[0].original, "final text")
    XCTAssertTrue(s.lines[0].isFinal)
}
```

- [ ] **Step 2: 跑测试确认失败**

Run: `swift test --filter SubtitleStoreTests`
Expected: FAIL(`stageVolatile`/`flushVolatile` 未定义)。

- [ ] **Step 3: 实现 stage/flush**

改 `SubtitleStore.swift`,加暂存字段与方法,并在 `commitFinal` 清暂存:

```swift
private var pendingVolatile: [Speaker: String] = [:]

/// 暂存中间态,不立即上屏(由节流器 flush)。
func stageVolatile(speaker: Speaker, text: String) {
    pendingVolatile[speaker] = text
}

/// 把所有暂存的中间态一次性上屏。
func flushVolatile() {
    for (speaker, text) in pendingVolatile {
        upsertVolatile(speaker: speaker, text: text)
    }
    pendingVolatile.removeAll()
}
```

在现有 `commitFinal(speaker:text:)` 开头加一行清除该说话人暂存:

```swift
@discardableResult
func commitFinal(speaker: Speaker, text: String) -> UUID {
    pendingVolatile[speaker] = nil       // 定稿后丢弃陈旧中间态
    // …原有逻辑不变…
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `swift test --filter SubtitleStoreTests`
Expected: PASS(新 3 条 + 原有全绿)。

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveSubtitle/Models/SubtitleStore.swift Tests/LiveSubtitleTests/SubtitleStoreTests.swift
git commit -m "feat: SubtitleStore volatile staging + flush (anti-flicker base)"
```

---

## Task 3: CaptionEngine 双轨泛化 + 节流 flush

**Files:**
- Modify: `Sources/LiveSubtitle/Pipeline/CaptionEngine.swift`
- Create: `Tests/LiveSubtitleTests/CaptionEngineTests.swift`

- [ ] **Step 1: 双轨改写 CaptionEngine**

`CaptionEngine.swift` 全文替换为:

```swift
import Foundation

@MainActor
final class CaptionEngine {
    let store: SubtitleStore
    private let translator = TranslationService()
    private struct Track { let source: AudioSource; let pipeline: TranscriptionPipeline }
    private var tracks: [Track]
    private var tasks: [Task<Void, Never>] = []
    private var flushTask: Task<Void, Never>?

    /// 默认双轨:对方(系统音)+ 我(麦克风)。测试可注入自定义轨。
    init(store: SubtitleStore, tracks: [(AudioSource, TranscriptionPipeline)]? = nil) {
        self.store = store
        let built = tracks ?? [
            (SystemAudioSource(), TranscriptionPipeline()),
            (MicSource(), TranscriptionPipeline()),
        ]
        self.tracks = built.map { Track(source: $0.0, pipeline: $0.1) }
    }

    func start(onError: @escaping @MainActor (String) -> Void) {
        // 翻译服务共享,暖机一次(失败=中文包未装)
        tasks.append(Task {
            do { try await translator.warmUp() }
            catch { onError("请在 系统设置→通用→语言与地区→翻译语言 安装 中文(简体)") }
        })
        // 每条轨:接 onError → ensureModel → start → 消费 + 喂
        for track in tracks {
            track.source.onError = { msg in Task { @MainActor in onError(msg) } }
            tasks.append(Task {
                do {
                    try await track.pipeline.ensureModel()
                    let events = try await track.pipeline.start()
                    let consume = Task { @MainActor in
                        for await e in events {
                            if e.isFinal {
                                let id = store.commitFinal(speaker: track.source.speaker, text: e.text)
                                Task { @MainActor in
                                    if let zh = await translator.translate(e.text) {
                                        store.attachTranslation(id: id, zh: zh)
                                    }
                                }
                            } else {
                                store.stageVolatile(speaker: track.source.speaker, text: e.text)
                            }
                        }
                    }
                    for await frame in track.source.frames() {
                        await track.pipeline.feed(frame)
                    }
                    await consume.value
                } catch {
                    onError("启动失败:\(error.localizedDescription)")
                }
            })
        }
        // 节流:每 120ms 把暂存的 volatile 一次性上屏
        flushTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                store.flushVolatile()
            }
        }
    }

    func stop() {
        flushTask?.cancel(); flushTask = nil
        tasks.forEach { $0.cancel() }; tasks = []
        let tracks = self.tracks
        Task { for t in tracks { await t.source.stop(); await t.pipeline.stop() } }
    }
}
```

- [ ] **Step 2: 写双轨 wiring 测试(假 source)**

`Tests/LiveSubtitleTests/CaptionEngineTests.swift`——用假 `AudioSource` 喂固定帧,验证不同说话人的事件分别落到 store。因 `TranscriptionPipeline` 依赖真 Speech 框架难注入,本测试聚焦**假 source 的 speaker 打标 + store 写入**这层可确定性逻辑:

```swift
import XCTest
@testable import LiveSubtitle

/// 不产帧的假轨,只用来验证 speaker 标签贯通 store。
private final class FakeSource: AudioSource, @unchecked Sendable {
    let speaker: Speaker
    var onError: (@Sendable (String) -> Void)?
    init(_ s: Speaker) { speaker = s }
    func frames() -> AsyncStream<AudioFrame> { AsyncStream { $0.finish() } }
    func stop() async {}
}

@MainActor
final class CaptionEngineTests: XCTestCase {
    func testStoreHandlesInterleavedSpeakersViaStageFlush() {
        // 直接驱动 store 的双轨状态机(引擎消费逻辑等价):对方 + 我 交错
        let store = SubtitleStore()
        store.stageVolatile(speaker: .other, text: "hello")
        store.stageVolatile(speaker: .me, text: "hi")
        store.flushVolatile()
        let id = store.commitFinal(speaker: .other, text: "hello there")
        store.attachTranslation(id: id, zh: "你好")
        XCTAssertEqual(store.lines.filter { $0.speaker == .me }.count, 1)
        let other = store.lines.first { $0.speaker == .other && $0.isFinal }
        XCTAssertEqual(other?.translated, "你好")
    }

    func testFakeSourceConformsAndSpeakerTagged() {
        XCTAssertEqual(FakeSource(.me).speaker, .me)
        XCTAssertEqual(FakeSource(.other).speaker, .other)
    }
}
```

- [ ] **Step 3: 跑测试 + 全量**

Run: `swift test`
Expected: 全绿(新增 CaptionEngineTests + 既有)。

- [ ] **Step 4: 编译 GUI**

Run: `bash scripts/build-app.sh`
Expected: `built: build/LiveSubtitle.app`

- [ ] **Step 5: Commit**

```bash
git add Sources/LiveSubtitle/Pipeline/CaptionEngine.swift Tests/LiveSubtitleTests/CaptionEngineTests.swift
git commit -m "feat: dual-track CaptionEngine (mic+system) with volatile throttle flush"
```

---

## Task 4: 双轨渲染 + 麦克风用途声明确认

**Files:**
- Modify: `scripts/build-app.sh`(确认 `NSMicrophoneUsageDescription` 存在)
- 检查:`Sources/LiveSubtitle/Overlay/SubtitleBarView.swift`(双色已在 Phase 1,确认两说话人交错正常)

- [ ] **Step 1: 确认 Info.plist 含麦克风用途**

Run: `grep -A1 NSMicrophoneUsageDescription scripts/build-app.sh`
Expected: 存在(Phase 1 已加)。若缺,在 build-app.sh 的 plist 段补 `NSMicrophoneUsageDescription`。

- [ ] **Step 2: 复核 SubtitleBarView 双说话人**

读 `SubtitleBarView.swift`,确认 `ForEach(store.lines.suffix(3))` 对 `.me`(蓝)/`.other`(橙)都渲染、chip 文案「我」/「对方」正确。Phase 1 已实现,预期无需改;若两说话人同时出现在 suffix(3) 内渲染异常再修。

- [ ] **Step 3: 编译**

Run: `swift build && bash scripts/build-app.sh`
Expected: `built: build/LiveSubtitle.app`

- [ ] **Step 4: Commit(如有改动)**

```bash
git add -A && git commit -m "chore: confirm mic usage desc + dual-speaker rendering for Phase 2"
```

---

## Task 5: 端到端手测(真机,用户执行)

**无法自动化**(需麦克风/屏录授权 + 双向英文语音 + 肉眼观察)。

- [ ] **Step 1:** `open build/LiveSubtitle.app` → 菜单栏 → 开始字幕。授权屏幕录制 + 麦克风(首次可能需退出重开生效)。
- [ ] **Step 2:** 放一段对方英文(浏览器)→ 观察橙色「对方」中文字幕;自己对麦克风说英文 → 观察蓝色「我」中文字幕。两轨并行、实时。
- [ ] **Step 3:** 外放场景验证 AEC:对方外放播放时自己不说话 → 不应出现蓝色「我」把对方的话转一遍(若出现且 P3b 已 GO,记录环境差异)。
- [ ] **Step 4:** 观察中间态是否明显闪烁(应被 120ms 节流平滑)。
- [ ] **Step 5:** 停止字幕 → 两轨干净停(麦克风/系统采集都停)。
- [ ] **Step 6:** 结果写入 `probes/RESULTS.md` "Phase 2 端到端" 小节。

---

## Phase 2 完成定义(DoD)

- 对方英文→中文(橙)、我英文→中文(蓝),两轨并行、实时。
- 外放时对方漏音不被误当「我」(AEC 生效),或已定耳机兜底。
- 中间态不明显闪烁(节流生效)。
- 麦克风未授权时降级为仅对方轨、不崩、有引导。
- `swift test` 全绿。

## 后续(Phase 3+)

显示三态切换、小窗 + 历史滚动、Pin、透明度/字号、音频路由变化、拖拽/缩放、延迟调优。
