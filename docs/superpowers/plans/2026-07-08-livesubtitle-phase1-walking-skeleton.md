# LiveSubtitle Phase 1 — 行走骨架 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 端到端跑通最小闭环 —— 采集系统音频(对方)→ 本地英文流式识别 → 本地英→中翻译 → 底部半透明字幕条显示(原文+译文)+ 菜单栏开始/停止。

**Architecture:** 单向数据流。`SystemAudioSource`(ScreenCaptureKit)产出 `AudioFrame`,经 `FormatConverter` 转成 analyzer 要求的 16kHz/Int16/单声道,喂给 `TranscriptionPipeline`(SpeechAnalyzer + SpeechTranscriber,开 `.fastResults`),终句触发 `TranslationService`(headless TranslationSession),结果写入 `@MainActor @Observable SubtitleStore`,`SubtitleBarView`(SwiftUI,承载于 `.nonactivating` NSPanel)订阅渲染。全 Swift Concurrency(actor + AsyncStream + Task)。

**Tech Stack:** Swift 6.2 · macOS 26 SDK · Xcode · SwiftUI + AppKit(NSPanel/MenuBarExtra)· Speech(SpeechAnalyzer)· Translation(TranslationSession)· ScreenCaptureKit · AVFoundation · XCTest。

**Phase 1 明确不做**(留后续计划):麦克风轨(我)、双轨并行、小窗模式、历史滚动、显示三态切换、Pin、透明度/字号/拖拽、回声消除。Phase 1 固定:单系统声轨、显示恒为"原文+译文"、字幕条一种浮窗。

**已验证前提**(Phase 0,见 `probes/RESULTS.md`,本计划直接 port 其真实代码):
- analyzer 输入格式 = `AVAudioFormat(pcmFormatInt16, 16000, 1ch)`。
- 系统音频源格式 = 48kHz / 2ch / Float32 → 必须 `AVAudioConverter` 重采样。
- `reportingOptions:[.volatileResults, .fastResults]`(`.fastResults` 把终句滞后 3.1s→1.7s)。
- Speech 模型 `AssetInventory.assetInstallationRequest(...).downloadAndInstall()` 可 headless 下。
- `TranslationSession(installedSource:target:)` headless 可用;语言包需用户在系统设置装一次(裸后台不能下)。
- ScreenCaptureKit 纯音频需"屏幕录制"TCC;编译需先 `sudo xcodebuild -license accept`(已做)。

---

## 文件结构

```
LiveSubtitle.xcodeproj
LiveSubtitle/
  LiveSubtitleApp.swift          App 入口 + MenuBarExtra(开始/停止)
  Info.plist                     NSScreenCaptureUsageDescription 等
  LiveSubtitle.entitlements      沙盒关闭/audio-input 等
  Models/
    SubtitleModels.swift         Speaker / DisplayMode / SubtitleLine / AudioFrame
    SubtitleStore.swift          @MainActor @Observable 状态机(全量历史)
  Audio/
    AudioSource.swift            protocol AudioSource
    FormatConverter.swift        任意源 → 16k/Int16/单声道
    SystemAudioSource.swift      ScreenCaptureKit 系统音频(port 自 probes/p3)
  Speech/
    TranscriptionPipeline.swift  SpeechAnalyzer + SpeechTranscriber(port 自 probes/p1b)
  Translation/
    TranslationService.swift     headless TranslationSession(port 自 probes/p2)
  Pipeline/
    CaptionEngine.swift          串起 source→convert→transcribe→translate→store
  Overlay/
    OverlayController.swift       NSPanel 生命周期
    SubtitleBarView.swift        SwiftUI 字幕条
LiveSubtitleTests/
    SubtitleStoreTests.swift
    FormatConverterTests.swift
    SubtitleModelsTests.swift
```

单一职责:纯逻辑(Models/Store/Converter)可单测;框架集成(Source/Pipeline/Service/Overlay)已被 Phase 0 探针验证,以"能编译 + 运行 app 观察"验收。测试策略见 spec §8。

---

## Task 0: 工程脚手架

**Files:**
- Create: `LiveSubtitle.xcodeproj`(Xcode GUI 生成)
- Create: `LiveSubtitle/Info.plist`, `LiveSubtitle/LiveSubtitle.entitlements`
- Create: 目录 `Models/ Audio/ Speech/ Translation/ Pipeline/ Overlay/`

- [ ] **Step 1: git 初始化**（当前目录尚非 git 仓库）

Run:
```bash
cd /Users/zhang/Project/live-subtitle
git init
printf '.DS_Store\nxcuserdata/\n*.xcuserstate\nbuild/\nDerivedData/\n' > .gitignore
git add .gitignore probes docs
git commit -m "chore: seed repo with Phase 0 probes and specs"
```
Expected: 初始提交成功。

- [ ] **Step 2: 用 Xcode 建 App 工程**

打开 Xcode → File > New > Project → macOS > App。设置:Product Name `LiveSubtitle`;Interface `SwiftUI`;Language `Swift`;取消 Core Data/Tests 勾选(测试 target 单独加)。保存到 `/Users/zhang/Project/live-subtitle`(与 `probes/`、`docs/` 同级)。

- [ ] **Step 3: 设最低部署版本 + 关沙盒(探针阶段简化)**

在 target > General 设 Minimum Deployments = macOS 26.0。
在 Signing & Capabilities:删除 App Sandbox capability(Phase 1 简化 TCC 调试;正式发布再收紧)。若保留沙盒,需勾 Audio Input,并知悉 ScreenCaptureKit 沙盒限制。

- [ ] **Step 4: Info.plist 加用途描述**

在 target > Info 增加键:
- `NSScreenCaptureUsageDescription` = `LiveSubtitle 采集系统音频用于实时中文字幕(仅音频)。`
- `NSMicrophoneUsageDescription` = `LiveSubtitle 采集麦克风用于识别你的发言(Phase 2)。`
- `LSUIElement` = `YES`（纯菜单栏 app,无 Dock 图标/主窗口）

- [ ] **Step 5: 加测试 target**

File > New > Target > Unit Testing Bundle,命名 `LiveSubtitleTests`。

- [ ] **Step 6: 建源码目录组**

在 `LiveSubtitle/` 下按上面文件结构创建组(group)文件夹:`Models Audio Speech Translation Pipeline Overlay`。

- [ ] **Step 7: 验证空工程可编译运行**

Run:
```bash
xcodebuild -project LiveSubtitle.xcodeproj -scheme LiveSubtitle -destination 'platform=macOS' build
```
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
git add LiveSubtitle LiveSubtitle.xcodeproj LiveSubtitleTests
git commit -m "chore: scaffold LiveSubtitle macOS app + test target"
```

---

## Task 1: 数据模型 SubtitleModels

**Files:**
- Create: `LiveSubtitle/Models/SubtitleModels.swift`
- Test: `LiveSubtitleTests/SubtitleModelsTests.swift`

- [ ] **Step 1: 写失败测试**

`LiveSubtitleTests/SubtitleModelsTests.swift`:
```swift
import XCTest
@testable import LiveSubtitle

final class SubtitleModelsTests: XCTestCase {
    func testSubtitleLineDefaults() {
        let line = SubtitleLine(speaker: .other, original: "hello")
        XCTAssertEqual(line.speaker, .other)
        XCTAssertEqual(line.original, "hello")
        XCTAssertNil(line.translated)
        XCTAssertFalse(line.isFinal)          // 新建默认是中间态
    }

    func testAudioFrameIsSendableValue() {
        let f = AudioFrame(pcm: [1, 2, 3], speaker: .other, hostTime: 42)
        XCTAssertEqual(f.pcm.count, 3)
        XCTAssertEqual(f.speaker, .other)
        XCTAssertEqual(f.hostTime, 42)
    }
}
```

- [ ] **Step 2: 运行,确认失败**

Run: `xcodebuild test -project LiveSubtitle.xcodeproj -scheme LiveSubtitle -destination 'platform=macOS' -only-testing:LiveSubtitleTests/SubtitleModelsTests`
Expected: 编译失败 `cannot find 'SubtitleLine' in scope`。

- [ ] **Step 3: 写实现**

`LiveSubtitle/Models/SubtitleModels.swift`:
```swift
import Foundation

enum Speaker: Sendable, Equatable { case me, other }        // 麦克风=me,系统声=other
enum DisplayMode: Sendable { case originalOnly, both, translatedOnly }
enum OverlayMode: Sendable { case bar, mini }

/// 跨 actor 的 Sendable 音频载体(不直接传 AVAudioPCMBuffer,后者非 Sendable)。
/// pcm 为已转换到 analyzer 目标格式(16k/Int16/单声道)的样本。
struct AudioFrame: Sendable {
    let pcm: [Int16]
    let speaker: Speaker
    let hostTime: UInt64
}

struct SubtitleLine: Identifiable, Sendable {
    let id: UUID
    let speaker: Speaker
    var original: String
    var translated: String?
    var isFinal: Bool

    init(id: UUID = UUID(), speaker: Speaker, original: String,
         translated: String? = nil, isFinal: Bool = false) {
        self.id = id; self.speaker = speaker; self.original = original
        self.translated = translated; self.isFinal = isFinal
    }
}
```

- [ ] **Step 4: 运行,确认通过**

Run: 同 Step 2 命令。
Expected: `Test Suite 'SubtitleModelsTests' passed`。

- [ ] **Step 5: Commit**

```bash
git add LiveSubtitle/Models/SubtitleModels.swift LiveSubtitleTests/SubtitleModelsTests.swift
git commit -m "feat: add subtitle domain models"
```

---

## Task 2: SubtitleStore 状态机

**Files:**
- Create: `LiveSubtitle/Models/SubtitleStore.swift`
- Test: `LiveSubtitleTests/SubtitleStoreTests.swift`

状态机规则(spec §5):中间态 upsert 同一说话人的"当前灰字行";`commitFinal` 把灰字行**原地提升**为终句(同 id)并返回 lineID;`attachTranslation(id:)` 按 id 回填。

- [ ] **Step 1: 写失败测试**

`LiveSubtitleTests/SubtitleStoreTests.swift`:
```swift
import XCTest
@testable import LiveSubtitle

@MainActor
final class SubtitleStoreTests: XCTestCase {
    func testVolatileUpsertKeepsSingleLinePerSpeaker() {
        let s = SubtitleStore()
        s.upsertVolatile(speaker: .other, text: "Hey")
        s.upsertVolatile(speaker: .other, text: "Hey can")
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertEqual(s.lines[0].original, "Hey can")
        XCTAssertFalse(s.lines[0].isFinal)
    }

    func testCommitFinalPromotesSameIdAndReturnsIt() {
        let s = SubtitleStore()
        s.upsertVolatile(speaker: .other, text: "Hey there")
        let volatileId = s.lines[0].id
        let finalId = s.commitFinal(speaker: .other, text: "Hey there.")
        XCTAssertEqual(finalId, volatileId)          // 原地提升,同 id
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertTrue(s.lines[0].isFinal)
        XCTAssertEqual(s.lines[0].original, "Hey there.")
    }

    func testNextVolatileStartsNewLineAfterFinal() {
        let s = SubtitleStore()
        _ = s.commitFinal(speaker: .other, text: "One.")
        s.upsertVolatile(speaker: .other, text: "Two")
        XCTAssertEqual(s.lines.count, 2)
        XCTAssertFalse(s.lines[1].isFinal)
    }

    func testAttachTranslationById() {
        let s = SubtitleStore()
        let id = s.commitFinal(speaker: .other, text: "Hello.")
        s.attachTranslation(id: id, zh: "你好。")
        XCTAssertEqual(s.lines[0].translated, "你好。")
    }

    func testTwoSpeakersHaveIndependentVolatileLines() {
        let s = SubtitleStore()
        s.upsertVolatile(speaker: .other, text: "A")
        s.upsertVolatile(speaker: .me, text: "B")
        s.upsertVolatile(speaker: .other, text: "A2")
        XCTAssertEqual(s.lines.count, 2)
        XCTAssertEqual(s.lines.first { $0.speaker == .other }?.original, "A2")
        XCTAssertEqual(s.lines.first { $0.speaker == .me }?.original, "B")
    }
}
```

- [ ] **Step 2: 运行,确认失败**

Run: `xcodebuild test -project LiveSubtitle.xcodeproj -scheme LiveSubtitle -destination 'platform=macOS' -only-testing:LiveSubtitleTests/SubtitleStoreTests`
Expected: 编译失败 `cannot find 'SubtitleStore' in scope`。

- [ ] **Step 3: 写实现**

`LiveSubtitle/Models/SubtitleStore.swift`:
```swift
import Foundation
import Observation

@MainActor
@Observable
final class SubtitleStore {
    private(set) var lines: [SubtitleLine] = []      // 全量内存历史(不落盘)
    var displayMode: DisplayMode = .both             // Phase 1 固定
    var overlayMode: OverlayMode = .bar

    /// 每个 speaker 的"当前未定稿灰字行"索引;定稿后清除。
    private var volatileIndex: [Speaker: Int] = [:]

    func upsertVolatile(speaker: Speaker, text: String) {
        if let i = volatileIndex[speaker] {
            lines[i].original = text
        } else {
            lines.append(SubtitleLine(speaker: speaker, original: text, isFinal: false))
            volatileIndex[speaker] = lines.count - 1
        }
    }

    /// 把当前灰字行原地提升为终句(同 id)。若无灰字行则新建一条终句。返回该行 id。
    @discardableResult
    func commitFinal(speaker: Speaker, text: String) -> UUID {
        if let i = volatileIndex[speaker] {
            lines[i].original = text
            lines[i].isFinal = true
            volatileIndex[speaker] = nil
            return lines[i].id
        } else {
            let line = SubtitleLine(speaker: speaker, original: text, isFinal: true)
            lines.append(line)
            return line.id
        }
    }

    func attachTranslation(id: UUID, zh: String) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[i].translated = zh
    }
}
```

- [ ] **Step 4: 运行,确认通过**

Run: 同 Step 2 命令。
Expected: 5 个测试全 pass。

- [ ] **Step 5: Commit**

```bash
git add LiveSubtitle/Models/SubtitleStore.swift LiveSubtitleTests/SubtitleStoreTests.swift
git commit -m "feat: add SubtitleStore state machine with volatile/final/translation"
```

---

## Task 3: FormatConverter

**Files:**
- Create: `LiveSubtitle/Audio/FormatConverter.swift`
- Test: `LiveSubtitleTests/FormatConverterTests.swift`

把任意输入 `AVAudioPCMBuffer` 转成 analyzer 目标格式 **16kHz / Int16 / 单声道**,输出 `[Int16]` 样本。目标格式实测自 Phase 0。

- [ ] **Step 1: 写失败测试**（用合成 48k/Float32/立体声 buffer 验证重采样与降采样后样本数≈len*16000/48000)

`LiveSubtitleTests/FormatConverterTests.swift`:
```swift
import XCTest
import AVFoundation
@testable import LiveSubtitle

final class FormatConverterTests: XCTestCase {
    /// 造一个 48kHz / Float32 / 2ch、时长 0.5s 的正弦 buffer
    private func makeSource(seconds: Double) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                channels: 2, interleaved: false)!
        let frames = AVAudioFrameCount(48000 * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<2 {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(frames) { p[i] = sin(Float(i) * 0.05) * 0.5 }
        }
        return buf
    }

    func testConvertsToMono16kInt16WithExpectedCount() throws {
        let conv = FormatConverter()          // 目标 16k/Int16/mono
        let out = try conv.convert(makeSource(seconds: 0.5))
        // 0.5s @16k ≈ 8000 样本,容许重采样边界 ±64
        XCTAssertEqual(Double(out.count), 8000, accuracy: 64)
        XCTAssertTrue(out.contains { $0 != 0 })   // 非静音
    }

    func testTargetFormatIs16kInt16Mono() {
        let conv = FormatConverter()
        XCTAssertEqual(conv.targetFormat.sampleRate, 16000)
        XCTAssertEqual(conv.targetFormat.channelCount, 1)
        XCTAssertEqual(conv.targetFormat.commonFormat, .pcmFormatInt16)
    }
}
```

- [ ] **Step 2: 运行,确认失败**

Run: `xcodebuild test -project LiveSubtitle.xcodeproj -scheme LiveSubtitle -destination 'platform=macOS' -only-testing:LiveSubtitleTests/FormatConverterTests`
Expected: `cannot find 'FormatConverter' in scope`。

- [ ] **Step 3: 写实现**

`LiveSubtitle/Audio/FormatConverter.swift`:
```swift
import AVFoundation

/// 任意输入 PCM → analyzer 目标格式(16kHz / Int16 / 单声道 交织)。
/// 每个输入源(SystemAudio 48k/2ch/Float32、后续 Mic+VP 24k/3ch/Float32)各建一个实例,
/// 因为 AVAudioConverter 与源格式绑定。
final class FormatConverter {
    let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                     sampleRate: 16000, channels: 1, interleaved: true)!
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    /// 转换一个输入 buffer;返回 Int16 交织样本(单声道即逐样本)。
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
```

- [ ] **Step 4: 运行,确认通过**

Run: 同 Step 2 命令。
Expected: 2 个测试 pass(样本数≈8000、目标格式正确)。

- [ ] **Step 5: Commit**

```bash
git add LiveSubtitle/Audio/FormatConverter.swift LiveSubtitleTests/FormatConverterTests.swift
git commit -m "feat: add FormatConverter to 16k/Int16/mono"
```

---

## Task 4: AudioSource 协议 + SystemAudioSource

**Files:**
- Create: `LiveSubtitle/Audio/AudioSource.swift`
- Create: `LiveSubtitle/Audio/SystemAudioSource.swift`

框架集成,无单测;验收=能编译 + 后续 Task 10 运行时观察到音频帧。代码 port 自已验证的 `probes/p3_syscapture/main.swift`。

- [ ] **Step 1: 写 AudioSource 协议**

`LiveSubtitle/Audio/AudioSource.swift`:
```swift
import Foundation

/// 一条带来源标的音频轨:产出已转换到 analyzer 格式的 AudioFrame 流。
protocol AudioSource {
    var speaker: Speaker { get }
    func frames() -> AsyncStream<AudioFrame>
    func stop() async
}
```

- [ ] **Step 2: 写 SystemAudioSource**

`LiveSubtitle/Audio/SystemAudioSource.swift`:
```swift
import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// 系统音频(=对方)。ScreenCaptureKit 纯音频采集;实测源格式 48k/2ch/Float32。
/// 需"屏幕录制"TCC 授权(首次调用 SCShareableContent.current 触发)。
final class SystemAudioSource: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate {
    let speaker: Speaker = .other
    private let converter = FormatConverter()
    private var stream: SCStream?
    private var continuation: AsyncStream<AudioFrame>.Continuation?

    func frames() -> AsyncStream<AudioFrame> {
        AsyncStream(bufferingPolicy: .bufferingNewest(32)) { cont in   // 实时优先,过载丢旧帧
            self.continuation = cont
            Task { await self.start() }
        }
    }

    private func start() async {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { return }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true   // 防自采回环
            config.sampleRate = 48_000
            config.channelCount = 2
            config.width = 2; config.height = 2          // 只要音频,视频给最小
            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "sysaudio"))
            try await s.startCapture()
            stream = s
        } catch {
            continuation?.finish()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio,
              let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        guard let samples = try? converter.convert(pcm) else { return }
        continuation?.yield(AudioFrame(pcm: samples, speaker: .other,
                                       hostTime: mach_absolute_time()))
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        continuation?.finish()
    }

    /// CMSampleBuffer → AVAudioPCMBuffer(Float32),供 FormatConverter 消费。
    private static func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              let fmt = AVAudioFormat(streamDescription: &asbdCopy(asbd)) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let abl = buf.mutableAudioBufferList
        CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0,
            frameCount: Int32(frames), into: abl)
        return buf
    }
    private static func asbdCopy(_ a: AudioStreamBasicDescription) -> AudioStreamBasicDescription { a }
}
```

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project LiveSubtitle.xcodeproj -scheme LiveSubtitle -destination 'platform=macOS' build`
Expected: `BUILD SUCCEEDED`(若 `AVAudioFormat(streamDescription:)` 报可变引用告警,把 `asbdCopy` 结果存入局部 `var` 再取地址)。

- [ ] **Step 4: Commit**

```bash
git add LiveSubtitle/Audio/AudioSource.swift LiveSubtitle/Audio/SystemAudioSource.swift
git commit -m "feat: add AudioSource protocol and ScreenCaptureKit SystemAudioSource"
```

---

## Task 5: TranscriptionPipeline

**Files:**
- Create: `LiveSubtitle/Speech/TranscriptionPipeline.swift`

port 自已验证的 `probes/p1b_realtime.swift`。开 `.fastResults`;吐 `(text, isFinal)`。模型 headless 自装。

- [ ] **Step 1: 写实现**

`LiveSubtitle/Speech/TranscriptionPipeline.swift`:
```swift
import Foundation
import Speech
import AVFoundation

struct TranscriptEvent: Sendable { let text: String; let isFinal: Bool }

/// 单轨英文流式识别。喂 AudioFrame,吐 TranscriptEvent(中间态/终句)。
actor TranscriptionPipeline {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var inputCont: AsyncStream<AnalyzerInput>.Continuation?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 16000, channels: 1, interleaved: true)!

    init() {
        transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],   // .fastResults:3.1s→1.7s
            attributeOptions: [.audioTimeRange])
        analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    /// 确保 en-US 模型已安装(headless 可下)。
    func ensureModel() async throws {
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }
    }

    /// 启动:返回结果事件流;内部起分析 Task。
    func start() async throws -> AsyncStream<TranscriptEvent> {
        try await analyzer.prepareToAnalyze(in: targetFormat)   // 预热降冷启动
        let (inStream, inCont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingNewest(32))
        inputCont = inCont
        try await analyzer.start(inputSequence: inStream)
        return AsyncStream { cont in
            Task {
                do {
                    for try await r in transcriber.results {
                        cont.yield(TranscriptEvent(text: String(r.text.characters), isFinal: r.isFinal))
                    }
                } catch { }
                cont.finish()
            }
        }
    }

    /// 喂入一帧(已是 16k/Int16/mono 样本)。
    func feed(_ frame: AudioFrame) {
        guard let buf = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                         frameCapacity: AVAudioFrameCount(frame.pcm.count)) else { return }
        buf.frameLength = AVAudioFrameCount(frame.pcm.count)
        frame.pcm.withUnsafeBufferPointer { src in
            buf.int16ChannelData![0].update(from: src.baseAddress!, count: frame.pcm.count)
        }
        inputCont?.yield(AnalyzerInput(buffer: buf))
    }

    func stop() async {
        inputCont?.finish()
        await analyzer.cancelAndFinishNow()
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project LiveSubtitle.xcodeproj -scheme LiveSubtitle -destination 'platform=macOS' build`
Expected: `BUILD SUCCEEDED`（enum 成员拼写以 `probes/p1b_realtime.swift` 编译通过版本为准)。

- [ ] **Step 3: Commit**

```bash
git add LiveSubtitle/Speech/TranscriptionPipeline.swift
git commit -m "feat: add TranscriptionPipeline (SpeechAnalyzer, .fastResults)"
```

---

## Task 6: TranslationService

**Files:**
- Create: `LiveSubtitle/Translation/TranslationService.swift`

port 自已验证的 `probes/p2_translation.swift`。headless；暖机一次;`notInstalled` 时抛可识别错误(供 UI 引导装包)。

- [ ] **Step 1: 写实现**

`LiveSubtitle/Translation/TranslationService.swift`:
```swift
import Foundation
import Translation

actor TranslationService {
    private var session: TranslationSession?
    enum TranslateError: Error { case notInstalled, failed }

    /// 暖机:构造 session + prepareTranslation。语言包未装则抛 notInstalled。
    func warmUp() async throws {
        let s = TranslationSession(installedSource: Locale.Language(identifier: "en"),
                                   target: Locale.Language(identifier: "zh-Hans"))
        do { try await s.prepareTranslation() }
        catch { throw TranslateError.notInstalled }   // 引导用户去系统设置装 en/zh 包
        session = s
    }

    /// 单句英→中。返回中文;失败返回 nil(调用方回退显示原文)。
    func translate(_ en: String) async -> String? {
        guard let s = session else { return nil }
        return try? await s.translate(en).targetText
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project LiveSubtitle.xcodeproj -scheme LiveSubtitle -destination 'platform=macOS' build`
Expected: `BUILD SUCCEEDED`。

- [ ] **Step 3: Commit**

```bash
git add LiveSubtitle/Translation/TranslationService.swift
git commit -m "feat: add headless TranslationService (en->zh-Hans)"
```

---

## Task 7: CaptionEngine 串管道

**Files:**
- Create: `LiveSubtitle/Pipeline/CaptionEngine.swift`

把 source → transcribe → translate → store 串起来。终句触发翻译(Phase 1 显示恒 both,故每条终句都翻)。

- [ ] **Step 1: 写实现**

`LiveSubtitle/Pipeline/CaptionEngine.swift`:
```swift
import Foundation

@MainActor
final class CaptionEngine {
    let store: SubtitleStore
    private let source = SystemAudioSource()
    private let pipeline = TranscriptionPipeline()
    private let translator = TranslationService()
    private var tasks: [Task<Void, Never>] = []

    init(store: SubtitleStore) { self.store = store }

    /// 启动整条链路。permissionError 通过 onError 回调上报(供 UI 引导授权/装包)。
    func start(onError: @escaping @MainActor (String) -> Void) {
        tasks.append(Task {
            do {
                try await pipeline.ensureModel()
                do { try await translator.warmUp() }
                catch { onError("请在 系统设置→通用→语言与地区→翻译语言 安装 中文(简体)") }

                let events = try await pipeline.start()
                // 消费识别结果 → 写 store,终句触发翻译
                let consume = Task { @MainActor in
                    for await e in events {
                        if e.isFinal {
                            let id = store.commitFinal(speaker: .other, text: e.text)
                            Task { @MainActor in
                                if let zh = await translator.translate(e.text) {
                                    store.attachTranslation(id: id, zh: zh)
                                }
                            }
                        } else {
                            store.upsertVolatile(speaker: .other, text: e.text)
                        }
                    }
                }
                // 采集 → 喂 pipeline
                for await frame in source.frames() {
                    await pipeline.feed(frame)
                }
                await consume.value
            } catch {
                onError("启动失败:\(error.localizedDescription)(检查屏幕录制授权)")
            }
        })
    }

    func stop() {
        tasks.forEach { $0.cancel() }; tasks = []
        Task { await source.stop(); await pipeline.stop() }
    }
}
```

- [ ] **Step 2: 编译验证**

Run: `xcodebuild -project LiveSubtitle.xcodeproj -scheme LiveSubtitle -destination 'platform=macOS' build`
Expected: `BUILD SUCCEEDED`。

- [ ] **Step 3: Commit**

```bash
git add LiveSubtitle/Pipeline/CaptionEngine.swift
git commit -m "feat: wire CaptionEngine (source->transcribe->translate->store)"
```

---

## Task 8: 字幕条视图 + NSPanel

**Files:**
- Create: `LiveSubtitle/Overlay/SubtitleBarView.swift`
- Create: `LiveSubtitle/Overlay/OverlayController.swift`

字幕条参照 Figma F1(原文+译文):我=蓝、对方=橙、英文灰、中文白、中间态灰。承载于 `.nonactivating` NSPanel。

- [ ] **Step 1: 写 SubtitleBarView**

`LiveSubtitle/Overlay/SubtitleBarView.swift`:
```swift
import SwiftUI

struct SubtitleBarView: View {
    var store: SubtitleStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.lines.suffix(3)) { line in       // 字幕条只显最近几行
                HStack(alignment: .top, spacing: 10) {
                    Text(line.speaker == .me ? "我" : "对方")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(line.speaker == .me ? Color.blue : Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(line.original)
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(line.isFinal ? 0.6 : 0.4))
                            .italic(!line.isFinal)
                        if let zh = line.translated {
                            Text(zh).font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
                        } else if line.isFinal {
                            Text("翻译中…").font(.system(size: 14)).foregroundStyle(.white.opacity(0.3))
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 900, alignment: .leading)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.1)))
    }
}
```

- [ ] **Step 2: 写 OverlayController(NSPanel)**

`LiveSubtitle/Overlay/OverlayController.swift`:
```swift
import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    private var panel: NSPanel?

    func show(store: SubtitleStore) {
        let host = NSHostingView(rootView: SubtitleBarView(store: store))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 200)
        let p = NSPanel(contentRect: host.frame,
                        styleMask: [.nonactivating, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        // 贴屏底部居中
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - 450, y: f.minY + 60))
        }
        p.orderFrontRegardless()
        panel = p
    }

    func hide() { panel?.orderOut(nil); panel = nil }
}
```

- [ ] **Step 3: 编译验证**

Run: `xcodebuild -project LiveSubtitle.xcodeproj -scheme LiveSubtitle -destination 'platform=macOS' build`
Expected: `BUILD SUCCEEDED`。

- [ ] **Step 4: Commit**

```bash
git add LiveSubtitle/Overlay
git commit -m "feat: add subtitle bar overlay on nonactivating NSPanel"
```

---

## Task 9: App 入口 + 菜单栏开始/停止

**Files:**
- Modify: `LiveSubtitle/LiveSubtitleApp.swift`(替换 Xcode 默认内容)

- [ ] **Step 1: 写 App 入口**

`LiveSubtitle/LiveSubtitleApp.swift`:
```swift
import SwiftUI

@main
struct LiveSubtitleApp: App {
    @State private var store = SubtitleStore()
    @State private var engine: CaptionEngine?
    @State private var overlay = OverlayController()
    @State private var running = false
    @State private var status = ""

    var body: some Scene {
        MenuBarExtra("LiveSubtitle", systemImage: "captions.bubble") {
            Button(running ? "停止字幕" : "开始字幕") { toggle() }
            if !status.isEmpty { Text(status).font(.caption) }
            Divider()
            Button("退出") { NSApplication.shared.terminate(nil) }
        }
    }

    @MainActor private func toggle() {
        if running {
            engine?.stop(); engine = nil; overlay.hide(); running = false; status = ""
        } else {
            let e = CaptionEngine(store: store)
            engine = e
            overlay.show(store: store)
            e.start(onError: { status = $0 })
            running = true
        }
    }
}
```

- [ ] **Step 2: 编译运行**

Run: `xcodebuild -project LiveSubtitle.xcodeproj -scheme LiveSubtitle -destination 'platform=macOS' build`
Expected: `BUILD SUCCEEDED`。

- [ ] **Step 3: Commit**

```bash
git add LiveSubtitle/LiveSubtitleApp.swift
git commit -m "feat: menu bar start/stop wiring, app entry"
```

---

## Task 10: 端到端手动验收(行走骨架)

无自动化(需真机 + 授权 + 系统声,见 spec §8)。按下列脚本人工过,记录结果。

- [ ] **Step 1: 首次授权**

从 Xcode Run(⌘R)。点菜单栏 LiveSubtitle → 开始字幕。首次弹"屏幕录制"授权 → 允许 → 若被要求重启 app,重启后再开始。

- [ ] **Step 2: 装翻译语言包(若菜单提示)**

若状态显示"请安装 中文(简体)":系统设置 → 通用 → 语言与地区 → 翻译语言 → 加 中文(简体),装好后重开始。

- [ ] **Step 3: 播放英文音频验证端到端**

浏览器播一段英文语音(YouTube 等)。观察:
- 底部字幕条出现 → 英文原文实时刷(灰,~100ms)
- 每句定稿后 → 下方出现中文(~2s 内)
- 「对方」橙色标签
记录:原文是否实时、中文是否在 ~2s 内出现、有无崩溃。

- [ ] **Step 4: 停止验证**

点 停止字幕 → 字幕条消失、采集停止(菜单栏 CPU 回落)。

- [ ] **Step 5: 记录验收结果**

把 Step 3/4 观察写入 `probes/RESULTS.md` 的"Phase 1 端到端"小节(延迟主观值、是否达到 spec §1 的"英文实时/中文≈2s")。

- [ ] **Step 6: Commit**

```bash
git add probes/RESULTS.md
git commit -m "docs: record Phase 1 walking-skeleton end-to-end results"
```

---

## Phase 1 完成定义(DoD)

- 单击菜单栏"开始字幕",播放英文语音,底部字幕条显示英文原文(实时)+ 中文译文(≈2s 追随),来源标「对方」。
- "停止字幕"干净停止(硬件采集停、面板隐藏)。
- 单测(Models/Store/Converter)全绿。
- 授权/装包缺失时有可读引导,不崩。

## 后续计划(各自独立 plan)

- **Phase 2**:MicSource(我)+ VoiceProcessing、双轨并行、「我/对方」双色、中间态防闪烁细化。
- **Phase 3**:小窗模式 + 历史滚动、显示三态切换、Pin、菜单栏透明度/字号。
- **Phase 4**:回声兜底、音频路由变化、拖拽/缩放、延迟调优 spike(finalize 强制盖章)、性能收尾。
```
