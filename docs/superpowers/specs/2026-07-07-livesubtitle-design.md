# LiveSubtitle — 实现设计 / Spec

> 状态:设计稿(brainstorming 产出),待用户复审 → 转 writing-plans 实现计划
> 日期:2026-07-07 · 平台:macOS 26/27 · 原生 Swift 6.2 · 全本地离线
> 上游需求:见 Obsidian `wiki/LiveSubtitle/prd.md`(产品决策已拍板,本 spec 不重开)
> v2:并入 subagent 批判性复审(2026-07-07)——量化延迟预算、修 P2 过度自信、补音频格式/背压/Sendable、探针分 KILL/DEGRADE、三态回退边界等。
> v3:并入 Phase 0 探针真机实测(2026-07-07,详见 `probes/RESULTS.md`)——P1/P2/P5a KILL 闸门通过;`.fastResults` 把终句滞后 3.1s→1.7s;实测 API 事实(16k/Int16、headless 差异);GitHub 同类实现(AirTranslate 等)独立印证设计。构建方式已定 = 完整 Xcode。

---

## 0. 本 spec 的范围

把 PRD(讨论稿)转成一份可执行的**实现设计**:延迟预算、分期、模块架构、Phase 0 探针规格(go/no-go 闸门)、数据模型、浮窗/视图、错误处理、测试策略。产品决策(全 Apple 本地、音轨分离、不做 TTS/导出/多语言等)已在 PRD 拍板,本文承接不复述。

**本次会话新确认的实现层决策:**
- **目标语言固定 英→中**,不切换(仅自用)。
- **浮窗两种模式可切换**:小窗(角落,历史滚动)⇄ 半透明字幕条(贴屏,只显最近、不滚动)。数据层持全量历史,两视图取用范围不同。
- **显示三态**:原文 / 原文+译文 / 译文。选"原文"时**不触发翻译**。
- **小窗支持 Pin 强制置顶**。
- **并发模型 = Swift Concurrency(actor + AsyncStream + Task)**。
- **de-risk 优先**:Phase 0 探针把未验证的新框架逐个摸一遍,是 go/no-go 闸门。

**已定(本次拍板):**
- **M2**:全本地是**不可让的底线**。P1/P2 任一硬 no-go = **项目暂停,不引入云端**。spec 据此定死,无云端活口。
- **构建方式**:**完整 Xcode `.xcodeproj`**(用户已装 Xcode,`/Applications/Xcode.app`;首次需 `sudo xcodebuild -license accept`)。探针阶段用 `swiftc` CLI 即可编译 macOS 26 框架,正式 app 用 Xcode 管 entitlements/签名/权限。

**Phase 0 探针实测结论(v3,已跑,详见 `probes/RESULTS.md`):**
- **P2 翻译 🟢**:`TranslationSession(installedSource:target:)` headless 可用;暖机后延迟 40–130ms;质量 ~80% 看得懂。**语言包需一次性 UI 安装**(裸后台 `canRequestDownloads=false`)。
- **P1 识别 🟢**:真人美/英音(8kHz 电话质)WER 2–4%;Speech 模型可 **headless 自装**(`AssetInventory.downloadAndInstall`,~15s)。
- **P1b 实时延迟 🟡→缓解**:原文中间态 ~0.1s 实时;终句滞后加 **`.fastResults`** 后 3.1s→**1.7s**;译文端到端 ≈ 2s(原文瞬时垫底)。
- **P5a 双 analyzer 并发 🟢**:两识别器真并行、不互扰。
- **实测 API 事实**:analyzer 输入格式 = **16kHz / Int16 / 单声道**;Speech 模型 headless 可下、Translation 语言包不可(需 UI)。

---

## 1. 延迟预算(PRD 第一优先级,量化)

> 全部为**初始目标,Phase 0 实测校准**;它们同时是 §3 探针的 go/no-go 数字闸门。测量口径见每行括注。

| 指标 | 目标 | Phase 0 实测 | 测量口径 |
|---|---|---|---|
| 中间态原文首现 | **< 300 ms** | ✅ ~100ms | 说话开始 → 屏上出现第一个灰字 |
| 终句原文定稿 | **< 800 ms** | ⚠️ ~1.7s(加 `.fastResults`,原 3.1s) | 说话停顿 → 该句 `isFinal` 稳定 |
| 终句→中文 | **< 400 ms** | ✅ 40–130ms(暖机后) | 终句定稿 → 中文出现(本地 TranslationSession) |
| 端到端译文(可读) | ~~< 1 s~~ **修正:≈ 2 s** | ⚠️ ~1.7s 终句 + ~0.4s 翻译 | 说话停顿 → 中文可读。**原文实时(~100ms)垫底,译文追随** |
| 回声漏入(P4) | 戴耳机 ~0%;外放 **< 5%** | ⏳ 待真机 | mic 轨转写句中混入对方内容的句子占比 |

> **端到端目标修正(v3 实测)**:原 <1s 目标对"译文可读"不现实——流式识别的终句定稿本身滞后 ~1.7s(已用 `.fastResults` 从 3.1s 压下)。**新现实:原文英文 ~100ms 实时,中文译文 ≈ 2s 追随。** 这仍优于"看不懂"的体验,且 §3 P1b 留了进一步压延迟的 spike(finalize 强制盖章 / 真实语速)。
| 识别 WER(P1) | 清晰美音 **< 15%**;重口音"可读"(不设硬门槛,记录) | 固定 WAV 人工抽样 |

超标即该探针 no-go(区分 KILL/DEGRADE,见 §3)。

---

## 2. 分期(de-risk 优先)

```
Phase 0  探针 / 可行性闸门 —— 分 KILL(崩=项目死/需重开 PRD)与 DEGRADE(崩=可降级出货)两档
  排序按"致命且轻量优先":
  ① P2 [KILL]    TranslationSession headless + 英→中质量 & 语言包   ← 不需屏录授权
  ② P1 [KILL]    SpeechAnalyzer 延迟 & 口音 & 语言模型下载          ← 喂 WAV 即可
  ③ P4 [DEGRADE] AVAudioEngine mic + VoiceProcessing 回声消除       ← 只需麦克风
  ④ P3 [DEGRADE] ScreenCaptureKit 纯系统音频 + 屏录授权             ← 需真机+TCC
  ⑤ P5 [KILL/DEGRADE] 双轨并行 + 双 analyzer 并发 + 延迟/热          ← 综合,最后跑
        ↓ 两个 KILL(P1/P2/P5核心)全过 → 立项进 Phase 1;DEGRADE 崩则记降级出货线
Phase 1  行走骨架:单轨(系统声)→ 识别 → 翻译 → 最简浮窗,端到端跑通、能看到中文
Phase 2  双轨采集 + 「我/对方」来源标 + 中间态灰字/终句定稿(防闪烁)
Phase 3  浮窗完全体:字幕条 ⇄ 小窗(历史滚动)、三态显示、Pin、菜单栏控制
Phase 4  打磨:回声兜底、音频路由变化处理、透明度/字号/拖拽缩放、性能与延迟收尾
```

**为什么 P2/P1 排最前**:唯二的 KILL 风险,且不需屏录授权、不需真机内录,拿音频文件+麦克风就能测。**M2 已拍板**:全本地是不可让的底线,P1/P2 任一硬 no-go = **项目暂停,不引入云端**(云端 STT/翻译违反 PRD 全本地 + 延迟优先,PRD 3.2 正因 ~1.5s 延迟否掉火山)。无"reroute 到云"活口。

---

## 3. 模块架构(Swift Concurrency)

```
AudioSource(protocol) ── func frames() -> AsyncStream<AudioFrame>; var label: Speaker
 ├─ MicSource         AVAudioEngine + inputNode.setVoiceProcessingEnabled(true)   label=.me
 └─ SystemAudioSource ScreenCaptureKit(capturesAudio, audio-only)                 label=.other
        │  各源原生格式不同(SCK≈48k CMSampleBuffer;VP mic 自改采样率/格式)
        ▼
   FormatConverter  ── AVAudioConverter,把各源重采样/转换到
                       SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith:)
        │  AsyncStream 用 .bufferingPolicy(.bufferingNewest(n)):实时优先,过载丢旧帧不堆内存
        ▼  每条轨一个独立 Task
   AudioFrame(Sendable) ─▶ TranscriptionPipeline(actor) SpeechAnalyzer+SpeechTranscriber(en-US)
                     │  AsyncSequence<结果>,result.isFinal 区分 中间态/终句
                     ▼  仅当显示模式含译文 且 isFinal 时触发
              TranslationService(actor)  TranslationSession(installedSource:en, target:zh-Hans)
                     ▼  await MainActor(volatile 更新做 ~40ms coalesce,防主线程洪泛)
              SubtitleStore(@MainActor @Observable, 全量历史)
                     ▼
   OverlayController ── OverlayPanel(NSPanel) ── SubtitleBarView / MiniWindowView(同 store 两视图)
   MenuBarExtra ────── 开停 / 浮窗模式 / Pin / 三态 / 透明度 / 字号
```

**并发/数据流要点(复审补强):**
- **音频帧载体 `AudioFrame` 是 Sendable 值类型**(承载已转换好的 PCM 数据 + 时间戳 + speaker),不直接跨 actor 传 `AVAudioPCMBuffer`/`CMSampleBuffer`(二者非 Sendable,Swift 6.2 严格并发会报错)。所有权随值转移。
- **FormatConverter 是显式环节**:CMSampleBuffer→PCM、各源采样率 → analyzer 要求格式的重采样,不能假设一致。
- **AsyncStream 背压**:`.bufferingNewest(n)` 明确"实时优先、过载丢旧帧",不 unbounded 堆内存。
- **volatile UI 更新节流**:两轨高频中间态 `await MainActor` upsert 做 ~40ms coalesce/合并,防主线程被压垮。

**Phase 0 实测 + GitHub 同类实现(AirTranslate 等)补强的具体参数:**
- **`SpeechTranscriber` reportingOptions 默认 `[.volatileResults, .fastResults]`** —— `.fastResults` 实测把终句滞后 3.1s→1.7s,同类生产代码亦如此配。
- **analyzer 输入格式实测 = `AVAudioFormat(pcmFormatInt16, 16000, 1ch)`**,`FormatConverter` 即以此为目标;并调 **`analyzer.prepareToAnalyze(in: fmt)` 预热**(降冷启动延迟,翻译侧同理暖机一次)。
- **`AudioFrame`/PCM buffer 用复用池**(参考 AirTranslate 48-buffer 环)避免实时分配抖动。
- **`SystemAudioSource` 的 CMSampleBuffer→Int16 PCM 转换**有现成范本(AirTranslate `pcmBuffer(from:)`,处理 float/int16 两种源)——P3 直接借鉴。
- **停止**:`inputContinuation.finish()` → cancel tasks → `analyzer.cancelAndFinishNow()` → 释放 `AssetInventory.reserve` 的 locale(印证 §6 M5)。
- **多 locale 配额**:若未来多语言,受 `AssetInventory.maximumReservedLocales` 限;当前固定 en→zh 无此约束。

**模块职责与边界(每个能独立测):**

| 模块 | 职责 | 依赖 | 输入→输出 |
|---|---|---|---|
| `AudioSource`(protocol) | 抽象"一条带来源标的音频轨" | — | 无 → `AsyncStream<AudioFrame>` + `Speaker` |
| `MicSource` | 麦克风采集 + VP 回声消除 | AVAudioEngine | 无 → 帧流(.me) |
| `SystemAudioSource` | 系统音频采集(纯音频) | ScreenCaptureKit | 无 → 帧流(.other) |
| `FormatConverter` | 重采样/格式转换到 analyzer 要求格式 | AVAudioConverter | 源帧 → 标准帧(纯逻辑,可单测) |
| `TranscriptionPipeline`(actor) | 单轨流式英文识别,吐 中间态/终句 | Speech | 帧流 → `AsyncStream<Transcript>` |
| `TranslationService`(actor) | 英→中,仅终句、仅含译文模式 | Translation | (lineID, 英文终句) → (lineID, 中文) |
| `SubtitleStore`(@Observable) | 字幕行状态机,持全量历史 | — | 识别/翻译事件 → 可观察行数组 |
| `OverlayController` | NSPanel 生命周期、模式、Pin、拖拽/缩放/透明度 | AppKit | store + 控制意图 → 屏上浮窗 |
| `MenuBarExtra` | 全部控制入口 | SwiftUI | 用户操作 → 控制意图 |

- 每条轨 = 一个 `Task`;**停止**见 §6(不止取消 Task)。
- `AudioSource` 抽 protocol → 两轨共用识别→翻译管道,差异只在"来源标签 + 是否开 VP";**也让 `MockSource`(喂 WAV)能跑通整条管线做离线测**。

---

## 4. Phase 0 探针规格(go/no-go 闸门)

> 每个探针:类别[KILL/DEGRADE] / 目标 / 做法 / **通过(数字)** / **否决** / **否决处置**。

### P2 [KILL] — TranslationSession 英→中 · 🟢 已通过(2026-07-07)
> 实测:headless 构造成功、暖机后 40–130ms、质量 ~80%。语言包需一次性 UI 安装。详见 `probes/RESULTS.md`。
- **目标**:先验 **headless 可行性**,再验质量与语言包。
- **断言顺序(先做第一条)**:
  1. **[待验证]** `TranslationSession(installedSource:target:)` 能**脱离 SwiftUI、后台**构造并 `translate`(历史上 session 强绑 `.translationTask` 修饰符,macOS 26 的公开 init 为二手实测所得、**我方未亲验**)。
  2. 语言包首次安装路径可控(能否 headless 下载 vs 必须走系统设置)。
  3. 质量:~30 句典型会议/电话英文,≥80% "能看懂大意"(人工判)。
- **通过**:①headless 跑通;②安装路径明确(哪怕"引导用户去系统设置一次");③满足延迟预算(终句→中文 < 400ms)且质量达标。
- **否决**:headless 调不通,或质量差到影响理解,或延迟超标。
- **否决处置(KILL,M2 已定)**:**无退路,项目暂停**。云翻译违反全本地/延迟支柱,不引入。
- **已核实**:on-device 免费无 entitlement;async。**待验证**:headless init 与后台可用性(第一断言);headless 下载语言包;`prepareTranslation()` 是否必须;批量 API 签名(`translate(batch:)` vs `translations(from:)`)。

### P1 [KILL] — SpeechAnalyzer / SpeechTranscriber · 🟢 已通过 / 🟡 延迟已缓解(2026-07-07)
> 实测:真人美/英音 WER 2–4%、模型 headless 自装;中间态 ~0.1s 实时;终句滞后加 `.fastResults` 后 3.1s→1.7s(P1b)。**待补**:印度等重口音样本;`finalize(through:)` 强制盖章、真实语速下滞后分布(实现期延迟 spike)。详见 `probes/RESULTS.md`。
- **目标**:识别延迟够低、口音够鲁棒、中间态/终句可用、语言模型可下载。
- **做法**:喂多口音英文 WAV(可自动化重复),读 `transcriber.results`,测首字/终句延迟 + 抽样 WER。
- **通过**:①中间态首现 < 300ms、终句定稿 < 800ms(§1);②清晰美音 WER < 15%,重口音"可读";③`AssetInventory` 装好 en-US 模型。
- **否决**:延迟超标,或主流口音大面积错乱。
- **否决处置(KILL,M2 已定)**:云 STT 违反支柱,不引入 → **项目暂停**。("仅清晰美音"若你能接受可作降级出货,但延迟/口音全崩则暂停。)
- **已核实**:结果是 AsyncSequence,`result.isFinal` 区分终句,`reportingOptions:[.volatileResults]` 开中间态;需 `AssetInventory.assetInstallationRequest` 预装模型;on-device 无特殊 entitlement。**待验证**:硬件门槛、enum 成员精确拼写。**注**:"比 Whisper 快 2×"是 MacStories 个人实测(2.2×),**非 Apple 官方基准**。

### P4 [DEGRADE] — AVAudioEngine mic + Voice Processing(回声消除)
- **目标**:外放场景 AEC 是否把"对方漏进麦克风轨"消得够干净。
- **做法**:`inputNode.setVoiceProcessingEnabled(true)`(engine stop 态设),外放播对方语音同时说话,看 mic 轨转写混入比例。
- **通过**:戴耳机 ~0%(基线);外放漏入 < 5%(§1)。
- **否决**:外放漏入严重到"我/对方"频繁串台。
- **否决处置(DEGRADE)**:外放场景明确降级为"仅戴耳机可靠"(PRD 已列戴耳机为最稳路径)——**仍可出货**。
- **已核实**:`setVoiceProcessingEnabled` 装 inputNode,engine 须 stop 态调用,会改采样率/格式(以 `inputNode.outputFormat(forBus:0)` 为准);需 `NSMicrophoneUsageDescription`。

### P3 [DEGRADE] — ScreenCaptureKit 纯系统音频 + 授权
- **目标**:只采系统音频拿 PCM;跑通屏录 TCC 授权流;对比 Core Audio Process Tap。
- **做法**:`capturesAudio=true`、`excludesCurrentProcessAudio=true`、最小视频尺寸;实现 `SCStreamOutput` 拿 `CMSampleBuffer` 转 PCM;走首次授权。
- **通过**:拿到稳定系统音频 PCM;授权流程可引导完成。
- **否决**:纯音频采集不可行,或授权体验不可接受。
- **否决处置(DEGRADE)**:改用 `AudioHardwareCreateProcessTap`(macOS 14.2+)纯音频路径(需先验其 TCC 要求)——路径 B,仍可出货。
- **已核实**:`capturesAudio` 是官方属性;**纯录音仍需屏录 TCC**,无 entitlement,须 `NSScreenCaptureUsageDescription`;回调交付 `CMSampleBuffer`。**待验证**:`SCStreamOutput` 参数标签拼写;Process Tap 是否也要屏录级 TCC。

### P5 [KILL/DEGRADE] — 双轨并行 + 双 analyzer 并发(综合)
- **目标**:VP mic(AVAudioEngine)+ 系统音(SCK)同进程并行;**两路 SpeechAnalyzer/SpeechTranscriber 同时实例化是否被支持**;端到端延迟达标;长会议持续负载的 CPU/热降频。
- **做法**:两条 actor 管线各起 Task 同时跑,含**双 analyzer 并发**;测端到端延迟、长时(≥30min)持续负载 CPU/热、有无 glitch/格式打架。
- **通过**:双轨 + 双 analyzer 稳定并行;端到端 < 1s;长时无明显热降频到影响延迟;无崩溃/爆音。
- **否决**:双轨/双 analyzer 互相拖延迟、争用、或热降频严重。
- **否决处置**:[DEGRADE] 降级"单轨可选"(一次只听我/对方);或换 Process Tap 组合。若双 analyzer 根本不支持并发则升级为需重排架构 [KILL 风险]。
- **已核实**:SCK 走媒体捕获流(CMSampleBuffer 回调),**不经 AVAudioEngine IO 图**,与 mic 不抢同一音频单元。**待验证**:双 analyzer 并发支持;VP+SCK 同进程稳定性、长时热——均需真机。**坑**:别在 AVAudioEngine 里混音回放(反馈环);AVAudioEngine 读不了系统音频/Process Tap 聚合设备。

---

## 5. 数据模型

```swift
enum Speaker { case me, other }
enum DisplayMode { case originalOnly, both, translatedOnly }
enum OverlayMode { case bar, mini }

struct AudioFrame: Sendable {              // 跨 actor 的 Sendable 载体(非 AVAudioPCMBuffer)
    let pcm: [Float]                        // 已转换到 analyzer 目标格式
    let speaker: Speaker
    let hostTime: UInt64
}

struct SubtitleLine: Identifiable {
    let id: UUID
    let speaker: Speaker
    var original: String                   // 英文(中间态持续更新)
    var translated: String?                // 中文(仅终句 + 曾处于含译文模式时填)
    var isFinal: Bool                       // false=中间态灰字, true=终句定稿
    let startedAt: Duration
}

@MainActor @Observable
final class SubtitleStore {
    private(set) var lines: [SubtitleLine]  // 全量内存历史(不落盘/不导出)
    var displayMode: DisplayMode
    var overlayMode: OverlayMode
    var isPinned: Bool

    func upsertVolatile(speaker:, text:)               // 中间态:更新该 speaker 当前灰字行
    func commitFinal(speaker:, text:) -> UUID          // 终句:把灰字行"原地提升"为终句(同 id),返回 lineID
    func attachTranslation(id: UUID, zh: String)       // 翻译按 id 回填(该行可能已定稿)
    func backfillMissingTranslations()                 // 切入含译文模式时,对历史 translated==nil 终句行惰性补翻
}
```

**状态机细节(复审补强):**
- **volatile→final 身份**:`commitFinal` 把当前灰字行**原地提升**为终句(**同一 id**,不另起重复行),返回其 `id`;随后该 speaker 新起下一条灰字行。
- **翻译 id 传递**:`commitFinal` 返回 `lineID` → 交给 `TranslationService`(携 id)→ `await MainActor` 调 `attachTranslation(id:zh:)`。回填按 id 定位,兼容"该行已被后续操作影响"。
- **翻译触发**:仅 `commitFinal` 且 `displayMode != .originalOnly` 时排队翻译;`.originalOnly` 期管线**跳过 TranslationService**(译文留 nil)。
- **三态回退边界(用户 Q3)**:
  - 从 `.originalOnly` 切到 `.both`/`.translatedOnly` → 调 `backfillMissingTranslations()` 对历史 nil 终句行**惰性补翻**。
  - `.translatedOnly` 且某行 `translated==nil`(补翻中/失败)→ 显示占位(如灰色原文 + "翻译中/—"),**不**在"仅译文"里默默显示英文正文(那自相矛盾)。
- **历史**:`lines` 全量内存;字幕条 `suffix(1...2)`,小窗全量可滚动。不落盘、不导出。

---

## 6. 浮窗 / 视图设计

**OverlayPanel(NSPanel)公共属性:**
- `styleMask: [.nonactivating, .borderless]`,`isFloatingPanel = true`,`becomesKeyOnlyIfNeeded = true` → 置顶、半透明、**不抢焦点**。
- `backgroundColor = .clear` + SwiftUI 内容层半透明底。可拖动/缩放/调透明度/字号。
- **[待验证 m4]** `.nonactivating` 面板不 becomeKey,小窗的**滚动/拖动交互**需 `isMovableByWindowBackground` 或自定义手势——Phase 3 验证可用性。

**两种模式(同一 store,两视图):**
- **SubtitleBarView(字幕条)**:贴屏(默认底部),`lines.suffix(1...2)`,不滚动。
- **MiniWindowView(小窗)**:角落独立窗,全量 `lines`,`ScrollView` 历史回看,自动到底、可上翻。

**Pin(仅小窗):**
- 关:`panel.level = .floating`。
- 开:**克制的 above-fullscreen 组合**——优先 `panel.level = .statusBar`(或稍高)+ `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`,随全屏 Space 常显;**避免用 `.screenSaver` 盖过系统弹窗**(过激,m4)。Phase 3 实测取最低够用层级。

**三态显示(每行渲染):**
- `.originalOnly`→只英文;`.both`→英+中;`.translatedOnly`→只中文(nil 走占位规则)。
- 中间态=灰字;终句=正常色。来源用**颜色 + 「我/对方」标**区分。

**Figma 交付**:可交互原型——点击切换 字幕条⇄小窗、三态、Pin、菜单栏;实时字幕流动感用滚动占位帧示意。

---

## 7. 错误处理

| 场景 | 处理 |
|---|---|
| 语言模型/语言包未安装 | 首启检测 → 引导安装(Speech 走 `AssetInventory`;Translation 若无 headless 下载则引导去系统设置一次),完成前禁用"开始" |
| 屏幕录制未授权 | 检测 TCC → 提示去"隐私与安全 → 屏幕与系统录音";未授权时系统声轨降级不可用,麦克风轨仍跑 |
| 麦克风未授权 | 请求权限;拒绝则麦克风轨不可用,系统声轨仍跑 |
| 某轨采集/识别失败 | 只影响该轨,`Task` 局部报错、可重启该轨,不拖垮另一轨 |
| 翻译失败/超时 | 保留原文,该行 `translated=nil`,含译文模式回退占位(§5);不阻塞识别 |
| **停止(复审 M5)** | **不止取消 Task**:显式 `engine.stop()` / `SCStream.stopCapture()` 停硬件采集 → `finalizeAndFinish` 冲刷未决终句 → 取消消费 Task。顺序写清 |
| **音频路由变化(复审 m5)** | 插拔耳机/切换输出会同时改回声策略与采集源(长会议常见)→ 监听 route change,Phase 4 处理(至少提示或重启对应轨) |

**原则**:单轨故障隔离;翻译永远"锦上添花",失败回退不阻塞识别主链路。

---

## 8. 测试策略

音频/内录/回声/双轨大量依赖真机+权限+人耳判。分两层:

- **可自动化(复审 m1:范围比初稿大)**——**可在 Mac runner 上跑**:
  - `SubtitleStore` 状态机:volatile upsert、final 原地提升(同 id)、翻译按 id 回填、三态切换 + 惰性补翻、translatedOnly nil 占位、`suffix` 取用 → 纯单元测试。
  - `FormatConverter`:CMSampleBuffer→PCM / 重采样 → 纯逻辑单测(给定输入断言输出格式/长度)。
  - **`MockSource` 喂固定 WAV → 跑通 采集抽象→识别→翻译 整条管线** → 断言转写含关键词 + 记录延迟(P1 半自动可重复)。
- **手动 spike(少数真机项)**:P2 headless/质量、P3 授权流、P4 回声、P5 双轨/热——按 §4 判据人工过,记进 Phase 0 报告。

**Phase 0 产出**:《探针结论表》——每个 P 记 通过/否决 + 实测数字(延迟、WER 抽样、翻译质量抽样、授权顺否、长时热),作为立项 go/no-go 依据。

---

## 9. 开放问题 / 实现前敲定

1. ~~构建方式~~ **已定**:完整 Xcode `.xcodeproj`(用户已装 Xcode)。
2. ~~M2 态度~~ **已拍板**:全本地不可让,P1/P2 任一硬 no-go = 项目暂停,不引入云端。
3. ~~Translation headless 语言包下载~~ **已答**(P2):**不可 headless**,须一次性 UI 安装 → 首启引导用户去系统设置装 en/zh 包。
4. **系统音频路径**:ScreenCaptureKit vs Core Audio Process Tap(P3 对比,待真机)。
5. **译文延迟进一步压低**(P1b 后续):`finalize(through:)` 强制盖章 / 真实语速滞后分布 → 实现期延迟 spike。默认已开 `.fastResults`(3.1s→1.7s)。
6. **剩余探针 P3/P4/P5b**:需带 entitlements 的 .app + TCC 授权,现 Xcode 已就绪可做。

**GitHub 参考实现(同类实时转写/翻译,已核对可借鉴)**:
- **himomohi/AirTranslate** — 语音→翻译,最像;`LiveSpeechTranscriber` 已印证 `.fastResults`、16k/Int16、`.bufferingNewest`、`prepareToAnalyze` 预热、CMSampleBuffer→PCM 转换、停止路径。
- yohasebe/speechdock、richlira/MeetingMindAI、FluidInference/swift-scribe、mozilla-mobile/firefox-ios(QuickAnswersKit)、rryam/AuralKit。

---

## 附:待 Phase 0 真机核实的 API 细节(编译期/已核实项已划掉)

- ~~Speech reportingOptions~~ 已核:`[.volatileResults, .fastResults]`(SDK 确有 `.fastResults`)。~~双 analyzer 并发~~ 已验(P5a)。**待**:重口音鲁棒性、硬件门槛。
- ~~Translation headless init/后台可用~~ 已验(P2 通过)。~~headless 下载~~ 已答(不可,需 UI)。**待**:`translate(batch:)` vs `translations(from:)` 批量取舍。
- ScreenCaptureKit:`SCStreamOutput` 参数标签;Process Tap 的 TCC 要求(P3,待真机)。
- 权限 API:`AVAudioApplication.requestRecordPermission` 精确形态(P4,待真机)。

---
*设计稿 v3 · 2026-07-07 · 承接 PRD + 复审 + Phase 0 实测 · 待复审 → writing-plans*
