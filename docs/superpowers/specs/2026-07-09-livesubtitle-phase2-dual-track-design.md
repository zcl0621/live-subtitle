# LiveSubtitle Phase 2 — 双轨(我 + 对方)Design

**日期:** 2026-07-09
**状态:** 已随 brainstorming 定稿,待落实现 plan(探针先行)

## Goal

在 Phase 1(系统音频→对方单轨,已端到端验证通过)基础上,**加入麦克风轨(我)**,实现开会/通话时的**双向字幕**:对方英文→中文(橙),我说的英文→中文(蓝),两轨并行、双色区分、中间态防闪烁。全程 all-Apple-local,无云。

## 锁定前提(承接既有产品决策,勿推翻)

- 说话人靠**音频轨道**区分(麦克风=我 / 系统音=对方),**不做声纹辨人**。
- 全本地:STT=SpeechAnalyzer/SpeechTranscriber,翻译=TranslationSession,离线免费。
- 低延迟 > 翻译质量。
- 场景:Google Meet + Mac 中转的英文电话。
- **用户实测确认:开会/通话时耳机、外放两种都有** → **默认启用 AEC(VoiceProcessing)**,两种场景都要稳。

## 架构:CaptionEngine 从 1 轨扩成 2 轨

Phase 1 已铺好双说话人地基:`Speaker.me/.other`、`SubtitleStore` 每说话人独立 volatile 行 + 按 commit 顺序交错的 final 行、`SubtitleBarView` 我=蓝/对方=橙双色。Phase 2 主要加**第二条输入轨 + 引擎并行两条 STT 管道**。

```
麦克风 →[AVAudioEngine + VoiceProcessing(AEC)]→ MicSource(.me) ──┐
                                                                ├→ CaptionEngine ──→ SubtitleStore ──→ 双色字幕条
系统音 →[ScreenCaptureKit]→ SystemAudioSource(.other) ──────────┘   (两条独立 TranscriptionPipeline,各自 en→zh)
```

- `MicSource` 实现已有的 `AudioSource` 协议(Phase 1 预留的扩展点);`FormatConverter` 直接复用(→16k/Int16/mono)。
- `CaptionEngine` 泛化:管理 N=2 条 `(source, pipeline)`;每条各自 feed 循环 + 消费循环,事件按 `source.speaker` 打标写入同一个 `SubtitleStore`。
- 翻译:两轨的 final 都各自触发 `TranslationService.translate` 后 `attachTranslation`(store 的 attach-by-id 已验证在交错下正确)。
- `SubtitleStore` / `SubtitleBarView`:预期基本不改(已支持双说话人);实现时验证两轨同时活跃、交错渲染正确。

## ⚠️ 两个 go/no-go 风险 → P3 探针先行

沿用 Phase 0 / M2 打法:硬风险先探针,通过再写实现 plan;**探针失败则暂停并重议架构,不硬凑、不假装**。

### 风险 1:两个 SpeechAnalyzer 能否并发
macOS 是否允许两个识别会话同时运行?资源/延迟是否可接受?
- **探针须证明:** 同时起两个 `SpeechAnalyzer`(各带一个 en-US `SpeechTranscriber`),各喂一段独立英文音频,**两边都能正常出结果**、延迟不显著恶化。
- **失败预案:** 改架构——如单分析器分时复用、或只保「对方」轨用分析器而「我」轨降级。属重大变更,失败即回到设计。

### 风险 2:VoiceProcessing AEC 能否消掉对方漏音
外放时对方声音从扬声器漏进麦克风。VP 的回声消除参考系统输出,理论上能把对方漏音从麦克风信号里去掉——**但需实测确认**,否则外放时对方的话会被麦克风轨当成「我」重复转一遍。
- **探针须证明:** 开 `setVoiceProcessingEnabled(true)`,外放播一段"对方"英文,同时麦克风开着(自己不说话),**麦克风轨基本不产生"对方那句话"的识别结果**(漏音被消掉)。
- **失败预案:** 外放场景靠耳机兜底 / 提示用户戴耳机;或加能量门限等二次抑制。

## MicSource + AEC 设计

- `AVAudioEngine`,inputNode 上 `setVoiceProcessingEnabled(true)` 开 AEC。VP 的回声参考即系统输出,对方漏音理论上被消掉。
- inputNode 装 tap 取 buffer(Phase 0 实测 VP 下为 24kHz/3ch/Float32)→ `FormatConverter` → 16k/Int16/mono → `AudioFrame(speaker:.me)`,经 `AsyncStream` 吐出。
- 麦克风未授权 → 降级为仅「对方」轨 + `onError` 提示(`NSMicrophoneUsageDescription` 已在 Info.plist)。

## 防闪烁设计

闪烁根源:`.volatileResults` 每秒多次中间态 → 每次 `upsertVolatile` → SwiftUI 重排;双轨同说更明显。

- **消费侧对 volatile 更新节流(coalesce,约 100–150ms 一次)**;`isFinal` 不节流,立即上屏。
- 配合字幕条布局稳定(定高、减少文字长度变化引起的跳动)。

## 明确不做(YAGNI,留 Phase 3)

显示三态切换(原文/双语/仅译文)、小窗模式 + 历史滚动、Pin、透明度/字号调节。

## 实现顺序(交给 writing-plans 细化)

1. **P3 探针**(先行,go/no-go):双 SpeechAnalyzer 并发 + VoiceProcessing AEC 效力。写入 `probes/`,结果记 `probes/RESULTS.md`。
2. 探针通过后:`MicSource`(AVAudioEngine + VP)→ `CaptionEngine` 双轨泛化 → 防闪烁节流 → 双轨渲染验证 → 端到端手测。

## Phase 2 完成定义(DoD)

- 开会时对方英文出中文(橙)、自己说英文出中文(蓝),两轨并行、实时。
- 外放场景对方漏音不被误当成「我」(AEC 生效)或已有耳机兜底方案。
- 中间态不明显闪烁。
- 麦克风未授权时降级不崩、有引导。
- 相关单测通过。
