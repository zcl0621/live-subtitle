# LiveSubtitle Phase 6 — 声纹说话人识别 Implementation Plan

**日期:** 2026-08-10
**Spec:** `../specs/2026-08-10-livesubtitle-phase6-voiceprint-design.md`
**分支:** `claude/voice-print-recognition-opensource-h8e535`

> ⚠️ **本 plan 在 Linux 容器内撰写,无 Swift 工具链,全文代码零编译验证。**
> 纯值逻辑(Task 2/3/4)可信度高,可照抄后靠单测把关;
> **凡涉及 FluidAudio API 的部分(Task 5/6)签名取自其文档而非源码,首次 build 必然要修。**
> 实现顺序已按此风险排布:先把能测的做完做实,再碰不确定的外部依赖。

> **进度(2026-08-11):Task 1–4 已在 macOS 真机落地并通过双重评审**,55 测试全绿
> (既有 31 + 新增 24)。commit:Task 1 `d77ac76`;Task 2 `2f45f5c`+`9daa237`;
> Task 3 `c014820`+`b4aed41`;Task 4 `5778223`+`5bcef20`。
> 下一步是 Task 0 探针(需人工录声纹样本),探针结论出来前**不要动 Task 5–10**。
> **P6a 全部完成(2026-08-14):🟢 GO,WeSpeaker 够用,CAM++ 对冲不启用。**
> Step 1:闭环 ✅,可只载 embedding 模型 ✅(Task 5 代码已按 0.15.5 真实 API 改写),
> **embedding 要自己 L2 归一化** ⚠️。
> Step 2/3:zh 间隔 +0.368、en 间隔 +0.405,**θ_me=0.70、θ_cluster=0.60**(spec §2 已更新)。
> Step 4:**短句兜底 1.0s → 2.0s**(`SpeakerAttributor.minDuration = 2.0`)。
> 详见 probes/RESULTS.md P6a 章节。**剩 P6b(负载)与 P7(zh-CN)待跑,P7 不阻塞声纹侧 Task 5/6/8。**
> 终审留给 Task 5/6 的两条提醒:
> ① `SubtitleLine.speaker` 目前是 `let`,Task 6 的 `attachSpeaker` 需要改成 `var`(一词改动);
> ② `VoiceprintProfile` 未记录 embedding 维度/模型标识 —— Task 5 落地时应补上,
>   否则将来按 CAM++ 对冲换模型后,旧 `voiceprints.json` 会以维度不匹配的向量
>   喂进 `cosine`(debug 断言崩、release 静默截断)。

## 置信度分级

| 级别 | 范围 | 说法 |
|---|---|---|
| 🟢 高 | Task 1/2/3/4/7/9 | 纯 Swift 值逻辑与既有代码重构,可由单测完全把关 |
| 🟡 中 | Task 8 | SwiftUI + AVAudioEngine 录音,模式常规但未编译 |
| 🔴 低 | Task 0/5/6 | 依赖 FluidAudio 真实 API 与真机 ANE 行为,**必须先跑探针** |

## File Structure

```
Sources/LiveSubtitle/
  Models/SubtitleModels.swift        ← 改:Speaker 拆成 Track + SpeakerID
  Models/SubtitleStore.swift         ← 改:字典键换 Track,新增 attachSpeaker / 改名映射 / meetingLanguage
  Pipeline/CaptionEngine.swift       ← 改:键换 Track,接声纹归属,语种门控翻译
  Speech/TranscriptionPipeline.swift ← 改:locale 参数化,终句带 audioTimeRange
  Audio/AudioSource.swift            ← 改:speaker → track
  Audio/MicSource.swift              ← 改:.me → .mic
  Audio/SystemAudioSource.swift      ← 改:.other → .system
  Overlay/SubtitleBarView.swift      ← 改:配色/标签读 SpeakerID
  Overlay/SettingsView.swift         ← 改:加「我的声纹」区块 + 会议语种
  Export/ObsidianExporter.swift      ← 改:displayName 读 SpeakerID
  Voiceprint/                        ← 新增整个模块
    AudioRingBuffer.swift
    SpeakerClusterer.swift
    VoiceprintStore.swift
    VoiceprintExtractor.swift
    SpeakerAttributor.swift
Tests/LiveSubtitleTests/
    AudioRingBufferTests.swift       ← 新增
    SpeakerClustererTests.swift      ← 新增
    VoiceprintStoreTests.swift       ← 新增
    (既有 3 个测试文件的 .me/.other 需机械替换)
probes/
    p6a_voiceprint.swift             ← 新增
    p7_zh_transcribe.swift           ← 新增
```

---

## Task 0: 探针(KILL 闸门,先跑再写代码)🔴

**Files:** `probes/p6a_voiceprint.swift`、`probes/p7_zh_transcribe.swift`、`probes/RESULTS.md`

### P6a — FluidAudio embedding 中英区分度(KILL)

- [ ] **Step 1: 装包跑通**

新建一个临时 SwiftPM 包(别直接改主 `Package.swift`,免得探针失败还要回滚):

```swift
.package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
```

先只验最小闭环:模型能否下载、`extractEmbedding` 能否单独调用。

**这一步要回答 spec §未决 1 的关键问题:能不能只加载 embedding 模型、跳过 segmentation 模型?**
如果 `extractEmbedding` 必须先初始化完整 `DiarizerManager`(连带加载 pyannote segmentation),算力与内存估算全部要重做,可能得改用 `DiarizerManager` 的完整路线。

- [ ] **Step 2: 区分度实测**

样本:自己中文读 5 段(各 ≥20s)、英文读 5 段;再找 2–3 个他人样本(中英各若干,家人/同事/播客片段皆可)。

量三组余弦分布:

| 组 | 期望 |
|---|---|
| 同人同语言 | 高(>0.8) |
| 异人同语言 | 低(<0.5) |
| 同人跨语言 | **不关心**(用户约束已排除),但顺手记一下,数据白拿 |

**判定:** 中文的「同人 vs 异人」两簇若明显可分 → 🟢 GO,按 spec 走。
若中文重叠严重而英文可分 → 🟡 换 CAM++(spec 的架构对冲生效,只换 `VoiceprintExtractor` 实现)。

- [ ] **Step 3: 定阈值**

从实测分布定 θ_me / θ_cluster,写回 spec §2。初值 0.75 / 0.70 仅为占位。
**θ_me 取「异人同语言」分布的上尾之外**,宁可漏判也别误判(误判会污染导出的会议记录归属)。

- [ ] **Step 4: 短音频衰减曲线**

对同一段语音,分别取 0.5s / 1s / 2s / 3s / 5s 抽 embedding,看余弦稳定性。
**这条定 spec §2「短句兜底」的 1.0s 阈值到底该取多少** —— 当前 1.0s 是拍的。

### P6b — 推理负载(DEGRADE)

- [ ] 2×SpeechAnalyzer + 2×声纹链路同跑 10 分钟,记 CPU%、内存、机身温度、有无掉帧。
      基线:现有双轨不带声纹的占用。**不阻塞实现,但要记进 RESULTS.md。**

### P7 — SpeechTranscriber zh-CN(KILL)

- [ ] **Step 1:** 打印 `SpeechTranscriber.supportedLocales`,确认 zh-CN / zh-Hans 在不在里面
- [ ] **Step 2:** 中文模型能否 headless 下载(P1 已证英文可以,`AssetInventory.assetInstallationRequest`)
- [ ] **Step 3:** 中文样本识别准确率抽样 + 终句滞后(对照 P1b 的英文 1.70s 中位)

**判定:** 不支持 zh-CN → spec §4 的中文会议整条路走不通,Task 7 作废,声纹部分仍可独立推进。

- [ ] **Step 4:** 三个探针结论按既有格式写进 `probes/RESULTS.md`

---

## Task 1: `Speaker` 拆成 `Track` + `SpeakerID`(纯重构)🟢

> **本任务不加任何新功能**,只做类型拆分,结束时 31 个既有测试必须全绿。
> 单独成 commit,方便出问题时二分。

**Files:** `SubtitleModels.swift`、`SubtitleStore.swift`、`CaptionEngine.swift`、`AudioSource.swift`、`MicSource.swift`、`SystemAudioSource.swift`、`SubtitleBarView.swift`、`ObsidianExporter.swift` + 3 个测试文件

- [ ] **Step 1: 新类型**

`SubtitleModels.swift`,删掉 `enum Speaker`,换成:

```swift
/// 路由用:哪条音频轨。承接旧 Speaker 在「每轨状态字典键」上的角色。
enum Track: String, Hashable, Sendable, CaseIterable {
    case mic     // 麦克风(旧 .me)
    case system  // 系统音(旧 .other)
}

/// 显示用:这句话是谁说的。
struct SpeakerID: Hashable, Sendable {
    let track: Track
    let kind: Kind

    enum Kind: Hashable, Sendable {
        case me              // 命中预注册声纹
        case cluster(Int)    // 会话内自动聚类
        case unresolved      // 判定中 / 音频太短
    }

    static func unresolved(_ track: Track) -> SpeakerID {
        SpeakerID(track: track, kind: .unresolved)
    }
}
```

- [ ] **Step 2: 机械替换**

| 位置 | 改法 |
|---|---|
| `AudioFrame.speaker: Speaker` | → `track: Track` |
| `SubtitleLine.speaker: Speaker` | → `speaker: SpeakerID` |
| `AudioSource.speaker` | → `var track: Track` |
| `MicSource` `.me` / `SystemAudioSource` `.other` | → `.mic` / `.system` |
| `SubtitleStore.volatileIndex/pendingVolatile` 的键 | → `Track`(**值域仍是 2,逻辑一行不动**) |
| `stageVolatile/upsertVolatile/commitFinal/currentVolatileText/attachVolatileTranslation` 的 `speaker:` 形参 | → `track: Track` |
| `CaptionEngine.lastVolatileSource/volatileInFlight` | → 键换 `Track` |

关键点:`upsertVolatile` / `commitFinal` 内部**建行时**要产出 `SpeakerID`:

```swift
let line = SubtitleLine(speaker: .unresolved(track), original: text, isFinal: false)
```

- [ ] **Step 3: 显示层临时兼容**

本任务不动 UI 行为,`SubtitleBarView` 与 `ObsidianExporter` 先按轨给出与现状一致的文案/配色:

```swift
// SubtitleBarView — Task 8 会替换成真身份配色
Text(line.speaker.track == .mic ? "我" : "对方")
    .background(line.speaker.track == .mic ? Color.blue : Color.orange)
```

- [ ] **Step 4: 测试机械更新**

3 个测试文件里的 `.me` → `.mic`、`.other` → `.system`,`speaker:` 实参名改 `track:`。
`SubtitleModelsTests` 里断言 `line.speaker` 的地方改断言 `line.speaker.track`。

- [ ] **Step 5:** `swift build` + `swift test` → **31 绿**,行为零变化。commit。

---

## Task 2: `AudioRingBuffer`(纯逻辑)🟢

**Files:** `Voiceprint/AudioRingBuffer.swift`、`Tests/LiveSubtitleTests/AudioRingBufferTests.swift`

按样本序号寻址的定长环形缓冲。时间基准 = 已写入的累计样本数,与 analyzer 数的是同一批样本,故 `audioTimeRange` 可精确换算(见 spec §架构)。

- [ ] **Step 1: 先写失败测试**

```swift
import XCTest
@testable import LiveSubtitle

final class AudioRingBufferTests: XCTestCase {
    func testSliceWithinRetainedWindow() {
        let buf = AudioRingBuffer(capacity: 100)
        buf.append(Array(repeating: 1, count: 40))    // 序号 0..<40
        buf.append(Array(repeating: 2, count: 40))    // 序号 40..<80
        XCTAssertEqual(buf.slice(from: 40, count: 5), [2, 2, 2, 2, 2])
        XCTAssertEqual(buf.slice(from: 35, count: 10), [1,1,1,1,1, 2,2,2,2,2])
    }

    func testEvictedRangeReturnsNil() {
        let buf = AudioRingBuffer(capacity: 100)
        buf.append(Array(repeating: 1, count: 150))   // 0..<50 已被覆盖
        XCTAssertNil(buf.slice(from: 0, count: 10))
        XCTAssertNotNil(buf.slice(from: 60, count: 10))
    }

    func testFutureRangeReturnsNil() {
        let buf = AudioRingBuffer(capacity: 100)
        buf.append(Array(repeating: 1, count: 40))
        XCTAssertNil(buf.slice(from: 30, count: 50))  // 越过已写入末尾
    }

    func testWrapAroundBoundary() {
        let buf = AudioRingBuffer(capacity: 10)
        buf.append([1,2,3,4,5,6,7,8])
        buf.append([9,10,11,12])                       // 绕回,保留序号 2..<12
        XCTAssertEqual(buf.slice(from: 6, count: 6), [7,8,9,10,11,12])
    }

    func testTimeRangeConversion() {
        let buf = AudioRingBuffer(capacity: 16000 * 60)
        buf.append(Array(repeating: 7, count: 16000 * 3))
        // 1.0s..1.5s @16k → 序号 16000..<24000
        XCTAssertEqual(buf.slice(seconds: 1.0..<1.5, sampleRate: 16000)?.count, 8000)
    }
}
```

- [ ] **Step 2: 实现**

```swift
import Foundation

/// 定长环形缓冲,按「累计写入样本序号」寻址。
/// 线程约束:仅由所属轨的采集回调写、由归属判定读,调用方自行保证串行(实践中同一 actor)。
final class AudioRingBuffer {
    private var storage: [Int16]
    private let capacity: Int
    /// 已累计写入的样本总数;也是下一个写入位置的绝对序号。
    private(set) var written: Int = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = Array(repeating: 0, count: capacity)
    }

    /// 当前仍可读取的最早绝对序号。
    var earliestAvailable: Int { max(0, written - capacity) }

    func append(_ samples: [Int16]) {
        for s in samples {
            storage[written % capacity] = s
            written += 1
        }
    }

    /// 取 [from, from+count) 的样本;越界(已被覆盖 / 尚未写入)返回 nil。
    func slice(from: Int, count: Int) -> [Int16]? {
        guard count > 0, from >= earliestAvailable, from + count <= written else { return nil }
        var out = [Int16]()
        out.reserveCapacity(count)
        for i in from..<(from + count) { out.append(storage[i % capacity]) }
        return out
    }

    /// 按秒区间取样本(秒 → 样本序号)。
    func slice(seconds: Range<Double>, sampleRate: Int) -> [Int16]? {
        let start = Int(seconds.lowerBound * Double(sampleRate))
        let end = Int(seconds.upperBound * Double(sampleRate))
        return slice(from: start, count: end - start)
    }
}
```

> `append` 逐样本写是为了正确性优先;若 P6b 显示成为热点,再换 `memcpy` 两段拷贝。

- [ ] **Step 3:** 测试全绿。commit。

---

## Task 3: `SpeakerClusterer`(纯逻辑)🟢

**Files:** `Voiceprint/SpeakerClusterer.swift`、`Tests/LiveSubtitleTests/SpeakerClustererTests.swift`

在线聚类。**整个声纹功能的判定核心,也是唯一能完全靠单测锁死的部分。**

- [ ] **Step 1: 先写失败测试**

```swift
import XCTest
@testable import LiveSubtitle

final class SpeakerClustererTests: XCTestCase {
    /// 造 L2 归一化向量:d 维,第 i 维为 1,其余 0(彼此正交,余弦=0)
    private func basis(_ i: Int, _ d: Int = 8) -> [Float] {
        var v = [Float](repeating: 0, count: d); v[i] = 1; return v
    }
    /// 两基向量的归一化混合,用于造「相似但不相同」
    private func blend(_ a: [Float], _ b: [Float], _ t: Float) -> [Float] {
        let v = zip(a, b).map { $0 * (1 - t) + $1 * t }
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / n }
    }

    func testMatchesEnrolledMeAboveThreshold() {
        let c = SpeakerClusterer(meProfiles: [basis(0)], thresholdMe: 0.75, thresholdCluster: 0.70)
        XCTAssertEqual(c.assign(basis(0), track: .mic).kind, .me)
    }

    func testDistinctVoiceBecomesNewCluster() {
        let c = SpeakerClusterer(meProfiles: [basis(0)], thresholdMe: 0.75, thresholdCluster: 0.70)
        XCTAssertEqual(c.assign(basis(1), track: .system).kind, .cluster(0))
        XCTAssertEqual(c.assign(basis(2), track: .system).kind, .cluster(1))
    }

    func testSimilarVoiceJoinsExistingCluster() {
        let c = SpeakerClusterer(meProfiles: [], thresholdMe: 0.75, thresholdCluster: 0.70)
        XCTAssertEqual(c.assign(basis(1), track: .system).kind, .cluster(0))
        // 与 basis(1) 余弦 ≈0.95,应归入同簇而非新建
        XCTAssertEqual(c.assign(blend(basis(1), basis(2), 0.2), track: .system).kind, .cluster(0))
    }

    /// θ_me > θ_cluster 的不对称必须生效:落在两阈值之间的向量不算「我」
    func testBetweenThresholdsIsNotMe() {
        let c = SpeakerClusterer(meProfiles: [basis(0)], thresholdMe: 0.95, thresholdCluster: 0.70)
        let near = blend(basis(0), basis(1), 0.25)   // 与 basis(0) 余弦 ≈0.93
        XCTAssertNotEqual(c.assign(near, track: .mic).kind, .me)
    }

    func testMeRecognizedOnBothTracks() {
        let c = SpeakerClusterer(meProfiles: [basis(0)], thresholdMe: 0.75, thresholdCluster: 0.70)
        XCTAssertEqual(c.assign(basis(0), track: .mic).kind, .me)
        // 外放漏音场景:我的声音出现在系统音轨,仍应认出是我
        XCTAssertEqual(c.assign(basis(0), track: .system).kind, .me)
    }

    func testMultipleMeProfilesTakeMax() {
        // 中英两份档案,命中任意一份即算「我」
        let c = SpeakerClusterer(meProfiles: [basis(0), basis(3)], thresholdMe: 0.75, thresholdCluster: 0.70)
        XCTAssertEqual(c.assign(basis(3), track: .mic).kind, .me)
    }

    func testCentroidUpdateKeepsUnitNorm() {
        let c = SpeakerClusterer(meProfiles: [], thresholdMe: 0.75, thresholdCluster: 0.70)
        _ = c.assign(basis(1), track: .system)
        _ = c.assign(blend(basis(1), basis(2), 0.1), track: .system)
        let norm = sqrt(c.centroids[0].reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 1e-4)
    }

    func testResetClearsClustersButKeepsMe() {
        let c = SpeakerClusterer(meProfiles: [basis(0)], thresholdMe: 0.75, thresholdCluster: 0.70)
        _ = c.assign(basis(1), track: .system)
        c.reset()
        XCTAssertTrue(c.centroids.isEmpty)
        XCTAssertEqual(c.assign(basis(0), track: .mic).kind, .me)
    }
}
```

- [ ] **Step 2: 实现**

```swift
import Foundation

/// 会话内在线说话人聚类。先比预注册的「我」,再比已有簇,都不中则新建簇。
/// 输入 embedding 必须已 L2 归一化(FluidAudio 的输出即是)。
final class SpeakerClusterer {
    private let meProfiles: [[Float]]
    private let thresholdMe: Float
    private let thresholdCluster: Float
    private(set) var centroids: [[Float]] = []
    private var counts: [Int] = []

    init(meProfiles: [[Float]], thresholdMe: Float, thresholdCluster: Float) {
        self.meProfiles = meProfiles
        self.thresholdMe = thresholdMe
        self.thresholdCluster = thresholdCluster
    }

    func assign(_ embedding: [Float], track: Track) -> SpeakerID {
        // 1) 先看是不是「我」——中英两份档案取 max
        let meScore = meProfiles.map { Self.cosine($0, embedding) }.max() ?? -1
        if meScore >= thresholdMe {
            return SpeakerID(track: track, kind: .me)
        }
        // 2) 再看归入哪个已有簇
        var bestIdx = -1
        var bestScore = -Float.infinity
        for (i, c) in centroids.enumerated() {
            let s = Self.cosine(c, embedding)
            if s > bestScore { bestScore = s; bestIdx = i }
        }
        if bestIdx >= 0, bestScore >= thresholdCluster {
            update(cluster: bestIdx, with: embedding)
            return SpeakerID(track: track, kind: .cluster(bestIdx))
        }
        // 3) 新建簇
        centroids.append(embedding)
        counts.append(1)
        return SpeakerID(track: track, kind: .cluster(centroids.count - 1))
    }

    func reset() { centroids.removeAll(); counts.removeAll() }

    /// 滑动平均更新簇中心后重新 L2 归一化(否则余弦尺度会漂)。
    private func update(cluster i: Int, with e: [Float]) {
        let n = Float(counts[i])
        var merged = zip(centroids[i], e).map { ($0 * n + $1) / (n + 1) }
        let norm = sqrt(merged.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { merged = merged.map { $0 / norm } }
        centroids[i] = merged
        counts[i] += 1
    }

    /// 两个已归一化向量的余弦 = 点积。长度不等按较短者截断(防御性)。
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var dot: Float = 0
        for i in 0..<n { dot += a[i] * b[i] }
        return dot
    }
}
```

- [ ] **Step 3:** 测试全绿。commit。

---

## Task 4: `VoiceprintStore`(档案持久化)🟢

**Files:** `Voiceprint/VoiceprintStore.swift`、`Tests/LiveSubtitleTests/VoiceprintStoreTests.swift`

- [ ] **Step 1: 类型 + 落盘**

```swift
import Foundation

struct VoiceprintProfile: Codable, Sendable, Equatable {
    enum Language: String, Codable, Sendable, CaseIterable { case chinese, english }
    let language: Language
    let embedding: [Float]
    let recordedAt: Date
    let durationSeconds: Double
}

/// 「我」的声纹档案(中/英各一份)。存 Application Support,不进 UserDefaults
/// ——256 维 Float 数组不适合塞 defaults,且未来要扩成多人档案库。
final class VoiceprintStore {
    private let fileURL: URL
    private(set) var profiles: [VoiceprintProfile] = []

    init(directory: URL? = nil) throws {
        let dir = try directory ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("LiveSubtitle", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("voiceprints.json")
        load()
    }

    /// 同语言档案覆盖(重录即替换)。
    func save(_ profile: VoiceprintProfile) throws {
        profiles.removeAll { $0.language == profile.language }
        profiles.append(profile)
        try persist()
    }

    func remove(language: VoiceprintProfile.Language) throws {
        profiles.removeAll { $0.language == language }
        try persist()
    }

    /// 供 SpeakerClusterer 用的 embedding 列表(两份都给,匹配时取 max)。
    var meEmbeddings: [[Float]] { profiles.map(\.embedding) }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([VoiceprintProfile].self, from: data)
        else { return }   // 首次运行 / 文件损坏 → 空档案,不崩
        profiles = decoded
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 2: 测试**(用临时目录,别碰真实 Application Support)

覆盖:空档案初始化 → 存中文 → 重开实例读回 → 同语言重录覆盖(仍只有 1 份)→ 中英各 1 份共存 → 删除 → **损坏 JSON 不崩溃且降级为空**。

- [ ] **Step 3:** 测试全绿。commit。

---

## Task 5: `VoiceprintExtractor`(FluidAudio 接缝)🔴

> **本任务的 API 细节以 Task 0 探针的实测为准,下面的签名是文档推测,大概率要改。**

**Files:** `Package.swift`、`Voiceprint/VoiceprintExtractor.swift`

- [ ] **Step 1: 加依赖**

```swift
dependencies: [
    .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4")
],
targets: [
    .executableTarget(
        name: "LiveSubtitle",
        dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
        path: "Sources/LiveSubtitle"
    ),
    ...
]
```

- [ ] **Step 2: protocol —— 换模型的唯一接缝**

```swift
import Foundation

/// 抽声纹向量。**独立成 protocol 是有意的架构对冲**:
/// 若 P6a 实测 WeSpeaker(VoxCeleb 英文训练)在中文上判别力不足,
/// 换成 3D-Speaker CAM++ 只需替换本实现,聚类/档案/UI 全不动。
protocol VoiceprintExtractor: Sendable {
    /// 输入 16kHz 单声道 Float32;输出 L2 归一化向量。
    func embed(_ samples: [Float]) async throws -> [Float]
}

/// Int16 → Float32 归一化。FormatConverter 产出 Int16,声纹模型要 Float32。
enum PCMConvert {
    static func int16ToFloat(_ samples: [Int16]) -> [Float] {
        samples.map { Float($0) / 32768.0 }
    }
}
```

- [ ] **Step 3: FluidAudio 实现**(✅ 已按 P6a Step 1 实测的 0.15.5 真实 API 改写,2026-08-14)

```swift
import CoreML
import FluidAudio

/// 轻量路线(P6a 已验证):只加载 wespeaker_v2.mlmodelc,segmentation 模型完全不碰。
/// mask 帧数从 embedding 模型自己的输入形状读取(实测 589 帧/10s 窗)。
/// 与完整 DiarizerManager.extractSpeakerEmbedding 路径的输出余弦 = 1.000000。
actor FluidAudioExtractor: VoiceprintExtractor {
    private var extractor: EmbeddingExtractor?
    private var maskFrames: Int = 0

    func prepare() async throws {
        // downloadIfNeeded 会把两个模型都下载到磁盘(共 ~13MB,只下一次),
        // 但内存里只载 embedding 这一个(0.07s)。
        _ = try await DiarizerModels.downloadIfNeeded()
        let url = /* Application Support/FluidAudio/Models 下找 wespeaker_v2.mlmodelc,参照 probes/p6a_voiceprint */
        let model = try MLModel(contentsOf: url, configuration: MLModelConfiguration())
        guard let shape = model.modelDescription.inputDescriptionsByName["mask"]?
            .multiArrayConstraint?.shape, shape.count >= 2
        else { throw ExtractError.badModel }
        maskFrames = shape[1].intValue
        extractor = EmbeddingExtractor(embeddingModel: model)
    }

    func embed(_ samples: [Float]) async throws -> [Float] {
        guard let extractor else { throw ExtractError.notPrepared }
        let mask = [Float](repeating: 1.0, count: maskFrames)
        guard let raw = try extractor.getEmbeddings(audio: samples, masks: [mask]).first
        else { throw ExtractError.empty }
        // ⚠️ P6a 实测:输出并非严格 L2 归一化(合成音 L2=1.037)。
        // SpeakerClusterer 的 cosine 是纯点积,这里必须自己归一化。
        let norm = sqrt(raw.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { throw ExtractError.empty }
        return raw.map { $0 / norm }
    }

    enum ExtractError: Error { case notPrepared, badModel, empty }
}
```

> ✅ **Task 0/P6a Step 1 已确认(2026-08-14,FluidAudio 0.15.5):**
> `extractSpeakerEmbedding` **不需要** segmentation 推理;embedding 模型可单独加载(0.07s,7.7MB),
> 热后单次推理 49ms(3s 音频,release)。首次推理有 ~3s 模型热身,预热时喂一段哑音频把它藏掉。
> **另:embedding 输出要自己 L2 归一化**(见上),spec「FluidAudio 输出即归一化」的说法不成立。
> 备选签名 `DiarizerManager.extractSpeakerEmbedding(from:)`(两模型都载入但同样不跑 segmentation)
> 可作为参考实现对拍。

- [ ] **Step 4: 模型下载时机与失败降级**

首次下载走网络,**必须不阻塞字幕启动**:后台预热,未就绪时所有行保持 `.unresolved`(仍显示字幕,只是没身份标注)。下载失败经既有 `onError` 通道提示,**不中断字幕**。

---

## Task 6: `SpeakerAttributor` + `CaptionEngine` 接线 🔴

**Files:** `Voiceprint/SpeakerAttributor.swift`、`Speech/TranscriptionPipeline.swift`、`Pipeline/CaptionEngine.swift`、`Models/SubtitleStore.swift`

- [ ] **Step 1: 终句带出 `audioTimeRange`**

`TranscriptionPipeline` 现在只吐 `text` + `isFinal`,要把时间区间带出来:

```swift
struct TranscriptEvent: Sendable {
    let text: String
    let isFinal: Bool
    /// 终句在 analyzer 音频时间轴上的区间(秒)。中间态为 nil。
    let audioRange: Range<Double>?
}
```

~~从 `r.text` 的 attributed runs 里取~~ **✅ P7 实测(2026-08-14):`SpeechTranscriber.Result.range`
就是非可选 `CMTimeRange`,直接 `r.range` 即可**(终句 range 起点与音频静音段实测吻合,
analyzer 时间轴与累计样本序号对齐成立)。换算:`range.start.seconds ..< range.end.seconds`。

同时 `feed()` 里把样本喂进环形缓冲(与喂 analyzer 同一批,时间基准天然对齐):

```swift
func feed(_ frame: AudioFrame) {
    ringBuffer.append(frame.pcm)   // ← 新增
    // ...既有喂 analyzer 逻辑不变
}
```

- [ ] **Step 2: `SpeakerAttributor` 编排**

```swift
/// 编排:切片 → 转 Float → 抽 embedding → 聚类 → SpeakerID
actor SpeakerAttributor {
    private let extractor: any VoiceprintExtractor
    private let clusterer: SpeakerClusterer
    private let minDuration: Double        // 短于此则沿用上一句身份
    private var lastIdentity: [Track: SpeakerID] = [:]

    func attribute(range: Range<Double>, buffer: AudioRingBuffer, track: Track) async -> SpeakerID {
        let duration = range.upperBound - range.lowerBound
        // 太短 → 沿用该轨上一句身份(连续性启发式)
        guard duration >= minDuration,
              let pcm = buffer.slice(seconds: range, sampleRate: 16000) else {
            return lastIdentity[track] ?? .unresolved(track)
        }
        do {
            let embedding = try await extractor.embed(PCMConvert.int16ToFloat(pcm))
            let id = clusterer.assign(embedding, track: track)
            lastIdentity[track] = id
            return id
        } catch {
            return .unresolved(track)   // 抽取失败不影响字幕本身
        }
    }
}
```

- [ ] **Step 3: store 加回填口**

与既有 `attachTranslation` 完全同构:

```swift
func attachSpeaker(id: UUID, speaker: SpeakerID) {
    guard let i = index(of: id) else { return }
    lines[i].speaker = speaker
}
```

- [ ] **Step 4: `CaptionEngine` 接线**

终句分支里,`commitFinal` 之后**异步**归属,不阻塞翻译:

```swift
if e.isFinal {
    let id = store.commitFinal(track: track.source.track, text: e.text)
    if let range = e.audioRange {
        Task { @MainActor in
            let speaker = await attributor.attribute(
                range: range, buffer: track.ringBuffer, track: track.source.track)
            store.attachSpeaker(id: id, speaker: speaker)
        }
    }
    // ...既有翻译逻辑不变
}
```

- [ ] **Step 5: 会话结束 `clusterer.reset()`**,避免上一场会议的簇污染下一场。

---

## Task 7: 会议语种开关 🟢

**Files:** `SubtitleModels.swift`、`SubtitleStore.swift`、`TranscriptionPipeline.swift`、`CaptionEngine.swift`、`LiveSubtitleApp.swift`

> 依赖 P7 探针结论。zh-CN 不被支持则整个 Task 作废。

- [ ] **Step 1:** `enum MeetingLanguage: String, Sendable, CaseIterable { case english, chinese }`
      带 `var locale: Locale`(en-US / zh-CN)与 `var needsTranslation: Bool`(chinese → **false**)
- [ ] **Step 2:** `SubtitleStore.meetingLanguage` 持久化(键 `ls.meetingLanguage`,默认 `.english`)
- [ ] **Step 3:** `TranscriptionPipeline.init(locale:)` 参数化
- [ ] **Step 4:** `CaptionEngine` 按 `needsTranslation` 门控 —— **中文会议连 `TranslationService.warmUp()` 都不调**,省掉整条链路
- [ ] **Step 5:** UI 加语种 Picker,**运行中置灰**(analyzer 在 start 时构建,中途换不了)
- [ ] **Step 6:** 单测:中文时 `needsTranslation == false`、locale 映射正确、持久化读回

---

## Task 8: UI —— 声纹录制 + 说话人配色 / 改名 🟡

**Files:** `SettingsView.swift`、`SubtitleBarView.swift`、`MiniWindowView.swift`、`SubtitleStore.swift`

- [ ] **Step 1: 设置页「我的声纹」区块**

中/英两个槽位,各显示状态(未录制 / 已录制 + 时长 + 日期)与「录制」「重录」「删除」。
录制用 `AVAudioEngine` 直采 → `FormatConverter` → 累积 ≥20s → `extractEmbedding` → `VoiceprintStore.save`。
录制中显示进度与实时电平,**低于 15s 不允许保存**(embedding 质量不够)。
给一段固定中/英提示文本让用户朗读,保证音素覆盖。

- [ ] **Step 2: 显示名与配色**

```swift
extension SpeakerID {
    var displayName: String {   // 改名映射优先,由 store 注入
        switch kind {
        case .me: return "我"
        case .cluster(let n): return "说话人 \(n + 1)"
        case .unresolved: return "…"
        }
    }
}
```

配色:`me` → 蓝(沿用现状);`cluster(n)` → 稳定色轮 `palette[n % palette.count]`;`unresolved` → 灰。
**色轮必须按簇号取模而非按出现顺序**,否则新说话人加入会让已有人换色。

- [ ] **Step 3: 改名**

`store.speakerNames: [SpeakerID: String]`,**瞬态不持久化**(跨会话簇号不稳定,持久化会张冠李戴)。
小窗里点标签弹输入框改名;`displayName` 优先读该映射。

- [ ] **Step 4:** 标签跳变过渡:`.unresolved` → 真身份时加 `.animation(.easeInOut(duration: 0.15))`,避免突兀闪跳。

---

## Task 9: Obsidian 导出适配 🟢

**Files:** `ObsidianExporter.swift`

- [ ] `displayName(for:)` 改吃 `SpeakerID` + 改名映射,输出 `- **我 / 张三 / 说话人 2**:原文 — 译文`
- [ ] **中文会议无译文**,导出行退化为 `- **说话人 1**:中文原文`(不留空的 ` — ` 尾巴)
- [ ] 单测覆盖两种语种下的导出格式

> ⚠️ **Task 7 评审发现的陷阱(2026-08-14):`store.lines` 从来没有被清空过**
> (全仓库无 `lines.removeAll` / 重新赋值)。同一次 app 运行里,第一场英文会议的行
> 会带着 `translated` 活到第二场中文会议里。于是「中文会议无译文」这条如果只用
> 合成行做单测,测试会绿,而真机导出依旧带 ` — 译文` 尾巴。
> **本 Task 要先决定 lines 的会话边界**:要么会话开始时清空,要么导出按会话分段
> (后者更符合「一次会议一篇笔记」的意图)。别只改 exporter 就宣布完成。

---

## Task 10: 真机端到端手测(用户执行)

- [ ] 设置页录中/英两份声纹,重启 app 确认仍在
- [ ] **英文会议**:多人参与,确认「我」在麦克风轨与系统音轨都被认出,其他人分成不同说话人且颜色稳定
- [ ] **中文会议**:确认识别出中文原文、不触发翻译、身份标注正确
- [ ] **外放漏音场景**:不戴耳机通话,确认对方的声音不再被错标成「我」(**这是本 phase 的顺带收益**)
- [ ] 长会话(>30min):确认簇不爆炸(同一人被拆成多个说话人 = θ_cluster 偏高)、内存平稳
- [ ] 记录主观正确率,写回 `RESULTS.md`

---

## 完成定义(DoD)

见 spec §完成定义。补充工程项:

- `swift build` 0 error;既有 31 测试 + 新增测试全绿
- Task 1 为独立的纯重构 commit,行为零变化
- 新增纯逻辑模块(环形缓冲 / 聚类 / 档案)单测覆盖分支与边界
- 探针结论写进 `probes/RESULTS.md`
- `backlog.md` 更新 Phase 6 状态

## 风险登记

| 风险 | 影响 | 应对 |
|---|---|---|
| **WeSpeaker 中文判别力不足** | 中文会议身份乱标 | P6a 先验;`VoiceprintExtractor` protocol 已留换 CAM++ 的接缝 |
| `extractEmbedding` 无法脱离完整 `DiarizerManager` | 内存/算力估算失效 | P6a Step 1 先答;必要时改走 `DiarizerManager` 完整路线 |
| `SpeechTranscriber` 不支持 zh-CN | Task 7 作废 | P7 先验;声纹部分不受影响,可独立交付 |
| 模型首次需联网下载 | 破坏「全本地」表述 | 与 Translation 语言包同性质;README/设置页明示;后台预热不阻塞字幕 |
| 簇爆炸(同一人被拆成多个) | 字幕身份乱跳 | θ_cluster 设置页可调;Task 10 长会话专项验 |
| `audioTimeRange` 取值方式与推测不符 | Task 6 卡住 | 🔴 已标注;真机核对 `AttributedString` 属性 key |
| 声纹判定延迟造成标签跳变 | 观感 | 回填模式(同 `attachTranslation`)+ 0.15s 过渡动画 |
