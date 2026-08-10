# LiveSubtitle Phase 6 — 声纹说话人识别 Design

**日期:** 2026-08-10
**状态:** 选型调研完成,设计定稿,待跑探针验证后写实现 plan
**前置约束(用户 2026-08-10 确认):** 不跨语言匹配;「我」的声纹中英各录一份;**一个会议只有一种语言**;中文会议不翻译。

## Goal

让字幕行标注**真实说话人**,而不是现在的「轨 = 人」假设:

- 麦克风轨可能有多人(会议室里同事一起说)
- 系统音轨可能有多人(远端多个参会者)
- 「我」由**预先录制的声纹**认出,不再等价于「麦克风轨」
- 未注册的人自动聚类成「说话人 1 / 2 / 3」,可手动改名

全程本地推理,不接任何三方云服务。

## 承接现状

| 现状 | 影响 |
|---|---|
| `enum Speaker { case me, other }`,麦克风=me、系统音=other | 核心待改;8 个源文件 + 3 个测试文件引用 |
| `TranscriptionPipeline` 已开 `attributeOptions: [.audioTimeRange]` | **关键利好**:终句自带音频时间区间,可直接定位要抽声纹的那段音频 |
| `FormatConverter` 统一输出 16k / 单声道 / **Int16** | 声纹模型要 **Float32**,需加一层转换(除以 32768) |
| `AudioFrame` 喂给 pipeline 后即丢弃 | 需新增每轨环形缓冲,保留最近 N 秒音频供回溯抽声纹 |
| `SpeechTranscriber` locale 写死 `en-US`;`TranslationService` 写死 en→zh | 中文会议下识别会出乱码,需参数化(见 §4) |
| P5a/P3a 已验证双 `SpeechAnalyzer` 真并行不互扰 | 但**再加声纹推理后的负载未验**,列为探针 |

## 选型结论

**采用 [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio)(Apache-2.0,纯 Swift + CoreML,走 ANE,macOS 14+)。**

调研过的备选与否决理由:

| 方案 | 结论 |
|---|---|
| **FluidAudio** | ✅ **选用**。SwiftPM 一行接入,零 C++ 依赖,CoreML 走 ANE,与现有纯 Swift 结构相容 |
| sherpa-onnx + CAM++ `campplus_sv_zh_en`(中英 code-switch 训练) | ❌ 否决。其唯一优势是跨语言鲁棒,而用户约束「不跨语言 + 中英分别注册」已消除该需求。代价是引 onnxruntime + C++ 依赖 + 模型手动管理 |
| Apple 原生 | ❌ 不存在。`SpeechAnalyzer` 只有 `SpeechTranscriber`/`DictationTranscriber`/`SpeechDetector`,**无 diarization 模块** |
| argmax SpeakerKit / soniqo speech-swift | ⏸ 备选,同为 pyannote CoreML 系,无明显优势 |

**接线参考(同技术栈,可直接抄):** [Marvinngg/ambient-voice](https://github.com/Marvinngg/ambient-voice)(MIT)—— macOS 原生 + Apple SpeechAnalyzer + FluidAudio diarization。

### 只用 embedding,不跑完整 diarization

FluidAudio 提供三条路线,**本设计只取最轻的一条**:

| 路线 | 取舍 |
|---|---|
| `DiarizerManager`(pyannote 分割 + WeSpeaker embedding + 聚类) | 完整时间线切分。**过重**——还要把时间线映射回句子 |
| `LSEENDDiarizer` / `SortformerDiarizer`(端到端流式) | 端到端出的是 slot 不是 embedding;文档明说 LSEEND「声音相似时注册会失败」;Sortformer 上限 4 人且是 NVIDIA Open Model License |
| **只用 `extractEmbedding()`** | ✅ **选用**。见下 |

理由:我们要的是**给每条字幕行标一个人**,不是精确的说话人时间线。既然终句自带 `audioTimeRange`,直接切那段音频抽一个 embedding 即可:

- 省掉 segmentation 模型的算力(现已有 2×SpeechAnalyzer + 翻译在跑)
- **天然与字幕行对齐**,不需要「时间线 → 句子」的区间映射,消掉一整类边界 bug
- 在线聚类自己写,约 30 行余弦运算

**代价(已接受):** 一句话内两人抢话,整句归一个人。实时字幕场景可接受。

### 残留风险(需探针证伪)

FluidAudio 的 embedding 模型是 **WeSpeaker ResNet34-LM(256 维,VoxCeleb 训练,英文为主)**。用户约束消除了「跨语言匹配」问题,但**没有**消除「模型在中文上整体判别力偏低」这一项(训练数据 domain mismatch)。

判断:区分一场会议里的 3–6 人,比 1 对 1000 声纹验证容易得多,**大概率够用**。但这是假设,**必须由 P6 探针实测证实或证伪**。

**架构对冲:** 抽 embedding 一步放在 `VoiceprintExtractor` protocol 后面。若中文实测不合格,换成 CAM++ zh-en 只需替换一个实现类,聚类/注册库/持久化/UI 全不动。

## 功能设计

### 1. 声纹注册(设置页)

新增「我的声纹」区块,两个独立槽位:

- **中文样本** / **英文样本**,各录 ≥20s(朗读固定提示文本,保证时长与内容覆盖)
- 录完即时 `extractEmbedding` → 存 **256 维 Float 数组**
- 显示状态:未录制 / 已录制(时长 + 录制日期)/ 重录 / 删除

**持久化:** `~/Library/Application Support/LiveSubtitle/voiceprints.json`。**不进 UserDefaults** —— 256 维 Float 数组不适合塞 defaults,且未来可能扩成多人档案库。

**匹配时两份都载入,取 max(cosine)。** 虽然一个会议只有一种语言,但两份都比无坏处,省掉「按语种选档案」的分支逻辑。

### 2. 每句归属判定

终句定稿时(`isFinal == true`)触发:

```
终句的 audioTimeRange
  → 从该轨环形缓冲切出对应样本(Int16)
  → 转 Float32(/32768)
  → extractEmbedding() → 256 维
  → 与「我」的两份档案比 cosine,取 max
      ≥ θ_me(默认 0.75) → 判定为「我」
  → 否则与本会话已有聚类中心比 cosine
      ≥ θ_cluster(默认 0.70) → 归入该簇,更新簇中心(滑动平均后重新 L2 归一化)
      否则 → 新建簇「说话人 N」
```

**阈值不对称是有意的:** θ_me > θ_cluster。把别人误判成「我」比漏判「我」更糟 —— 会污染 Obsidian 导出的会议记录归属。两个阈值都放设置页可调。

**短句兜底:** 时长 < 1.0s 的终句 embedding 不可靠,**沿用该轨上一句的身份**(连续性启发式),不新建簇。

**系统音轨的先验:** 系统音理论上不含「我」的声音(`excludesCurrentProcessAudio` 已开,且通话 app 通常不回放本人语音)。但不做硬性排除,交给余弦判断 —— 留作实测后的可选优化。

### 3. 两级身份:volatile 按轨,final 按声纹

**这是本设计缩小改动面的关键。**

中间态(灰字)**不做**声纹判定 —— 它还在流式增长,`audioTimeRange` 未定,时长可能不足。所以:

| 阶段 | 身份来源 |
|---|---|
| volatile(未定稿) | **轨级占位**:「麦克风」/「系统音」 |
| final(定稿) | 声纹判定出的真实身份 |

由此,旧 `Speaker` 枚举**按职责一分为二**:

```swift
/// 路由用:哪条音频轨。取代旧枚举在「字典键 / 每轨状态」上的角色。
enum Track: Hashable, Sendable { case mic, system }

/// 显示用:这句话是谁说的。
struct SpeakerID: Hashable, Sendable {
    let track: Track
    let kind: Kind
    enum Kind: Hashable, Sendable {
        case me              // 命中预注册声纹
        case cluster(Int)    // 会话内自动聚类
        case unresolved      // 判定中 / 音频太短
    }
}
```

好处:`SubtitleStore.volatileIndex`、`pendingVolatile`,以及 `CaptionEngine.lastVolatileSource`、`volatileInFlight` 这些**每轨状态的字典键改成 `Track` 即可,值域仍是 2,逻辑一行不动**。只有 `SubtitleLine.speaker` 升级成 `SpeakerID`。

**回填而非阻塞:** 终句先以 `.unresolved` 上屏,声纹判定完成后经 `store.attachSpeaker(id:speaker:)` 回填。这与现有 `attachTranslation` 的回填模式完全一致,不引入新范式。标签会有一次跳变(灰「…」→ 真实身份),延迟预计 <100ms。

### 4. 会议语种开关(顺带解决的 ASR 缺陷)

现状 `SpeechTranscriber` 写死 `en-US`。用户确认「一个会议只有一种语言」后,不需要 code-switching,只需**会话级开关**:

- `SubtitleStore.meetingLanguage: MeetingLanguage { .english, .chinese }`,持久化
- `TranscriptionPipeline(locale:)` 参数化
- **中文会议不翻译**(用户 2026-08-10 确认):`CaptionEngine` 跳过整条翻译链路,连 `TranslationService.warmUp()` 都不调
- **只能在开始字幕前切换**(analyzer 在 start 时构建),运行中 UI 置灰

### 5. 说话人改名

字幕小窗 / 控制面板里点说话人标签可改名(`说话人 2` → `张三`)。改名映射 `[SpeakerID: String]` 存在 store,**仅本会话有效,不持久化**(跨会话的聚类编号本就不稳定)。

真要跨会议记住某人,是「把他也注册进声纹库」的功能 —— 留 Phase 7。

### 6. 配色与导出

- **配色**:`me` → 蓝(沿用现状);`cluster(n)` → 稳定色轮按 n 取模;`unresolved` → 灰
- **Obsidian 导出**:`displayName(for:)` 改读 `SpeakerID` + 改名映射,输出 `- **我 / 张三 / 说话人 2**:原文 — 译文`

## 架构

### 新增模块 `Sources/LiveSubtitle/Voiceprint/`

| 文件 | 职责 |
|---|---|
| `VoiceprintExtractor.swift` | protocol + FluidAudio 实现。**换模型的唯一接缝** |
| `VoiceprintStore.swift` | 「我」的档案(中/英两份 embedding)持久化到 Application Support |
| `SpeakerClusterer.swift` | 在线聚类:余弦、簇中心滑动平均、阈值判定。**纯值逻辑,可完整单测** |
| `AudioRingBuffer.swift` | 每轨保留最近 N 秒 16k Int16 样本,按样本序号切片。**纯值逻辑,可完整单测** |
| `SpeakerAttributor.swift` | 编排:切片 → 转 Float → 抽 embedding → 聚类 → 出 `SpeakerID` |

### 时间基准对齐(关键正确性点)

`audioTimeRange` 是 **analyzer 音频时间轴**(自 analyzer 启动起算的秒数),**不是墙钟**。

环形缓冲以「已喂给该 analyzer 的累计样本数」为时间基准 —— 与 analyzer 数的是同一批样本,故 `样本序号 = audioTimeRange.start × 16000` **精确对齐,无时钟漂移**。这是本设计不需要做时间戳校准的原因。

**容量:** 实测终句滞后 max 4.72s(`.fastResults` 后 2.18s),单句可能长达 15s。保留 **60s** → 16000 × 60 × 2B ≈ **1.9MB/轨**,可忽略。

### 负载

新增 2 条推理链路(每轨每终句一次 embedding)。WeSpeaker ResNet34 在 ANE 上对几秒音频预计 <50ms,且**仅在终句触发**(非连续推理),预计远轻于已在跑的 2×SpeechAnalyzer。但这是估算,**列入 P6 探针实测**。

### 模型下载

FluidAudio 模型首次从 HuggingFace 自动下载,之后全离线。**这是「实时链路 100% 本地」边界的一次变更**,性质与 Translation 语言包的一次性安装相同,须在 README/设置页明示。可用 `ModelRegistry.baseURL` 换源。

## 探针(实现前必跑,遵循 Phase 0 惯例)

| 探针 | 类别 | 验什么 |
|---|---|---|
| **P6a** FluidAudio embedding 中英区分度 | **KILL** | 装包、`extractEmbedding` 跑通;中文/英文各录 N 人样本,量同人 vs 异人的余弦分布是否可分;定出 θ_me / θ_cluster。**中文不合格 → 切 CAM++ 备选** |
| **P6b** 推理负载 | DEGRADE | 2×SpeechAnalyzer + 2×声纹链路并跑,量 CPU/ANE 占用与发热 |
| **P7** `SpeechTranscriber` zh-CN | **KILL** | zh-CN 是否在 `supportedLocales`;模型能否 headless 下载(P1 已证英文可以,中文待验);中文识别准确率抽样 |

> P6a 与 P7 都是 KILL 级:前者不过则换模型,后者不过则中文会议这条路走不通。

## 明确不做

- **跨语言声纹匹配**(用户约束已排除)
- **code-switching / 单场会议双语**(用户约束已排除)
- **句内重叠语音分离**(抢话整句归一人,已接受)
- **跨会话记住陌生说话人**(改名仅本会话有效;留 Phase 7 的「多人声纹库」)
- **完整 diarization 时间线**(只做句级归属)
- **中译英**(用户确认中文会议不翻译)

## 完成定义(DoD)

- 设置页可录制并保存中/英两份「我的声纹」,重启后仍在
- 麦克风轨与系统音轨的字幕行,均按声纹标注身份而非按轨
- 「我」在两条轨上都能被认出(含外放漏音时,对方的声音不再被错标成「我」)
- 未注册者自动分成「说话人 N」,可改名,配色稳定不跳
- 会议语种开关生效:中文会议出中文原文、不触发翻译
- 短句 / 判定中的行有合理占位,不出现空白或错标
- 新增纯逻辑模块(环形缓冲、聚类、档案持久化)单测覆盖;既有 31 个测试全绿
- 真机验收:一场中文会议 + 一场英文会议,身份标注正确率由用户主观判定

## 未决 / 待验证

> 以下为**尚未在真机核对**的事项,实现时逐条确认。

1. **FluidAudio API 签名来自其文档,未经编译验证。** `extractEmbedding` 是否需先初始化完整 `DiarizerManager`、能否只加载 embedding 模型而跳过 segmentation 模型 —— 需实机确认。若不能单独加载,算力估算要重做。
2. **`SpeechTranscriber` 的 zh-CN 支持情况**(见 P7)。
3. **θ_me / θ_cluster 的具体取值**由 P6a 定,当前 0.75 / 0.70 是基于 FluidAudio 文档 `clusteringThreshold` 默认 0.7 的初值。
4. **中文会议下 `.fastResults` 的终句滞后**是否与英文相当(P1b 只测了英文)。
