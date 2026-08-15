# Phase 0 探针结论表

> 真实运行结果记录。每条为二进制/工具的实际输出,不加工。
> 机器:macOS 27.0(build 26A5378j)· SDK macOS 26.0 · Swift 6.2 · CLT(无完整 Xcode)· Apple silicon

---

## P2 [KILL] — TranslationSession headless 英→中

**状态:🟢 通过(装包后复测:延迟远超标、质量 ~80% 达标)**

**装包后复测(2026-07-07,用户已装 zh-Hans 包):**
- 延迟:首句 0.84s(冷启动一次性预热),之后**稳定 40–130ms**,**远低于 400ms 目标**。真机开始时预热一次即可。
- 质量:15 句约 11–12 句清楚;2 句习语/同形词跑偏("standup"→单口相声、"you're breaking up"→你要分手了);1–2 句生硬可猜。**≥80% 看得懂,达标**(质量非首要已接受)。
- `status = installed`;`prepareTranslation()` 0.01s OK;15/15 成功。
- **go/no-go:通过。** 唯一代价:语言包需一次性 UI 安装(裸后台 `canRequestDownloads=false`)。

---

### (历史)装包前首测 — 🟡 卡在语言包未安装

探针:`probes/p2_translation.swift`(`swiftc -target arm64-apple-macos26.0`)

| 断言 | 结果 | 证据 |
|---|---|---|
| API 在 CLT SDK 存在 | ✅ | SDK 有 `TranslationSession.init(installedSource:target:)`、`translate(_:)`、`Response.targetText`;编译零报错 |
| headless 构造(脱离 SwiftUI) | ✅ | `[2] headless init 成功`,纯 CLI 无 SwiftUI |
| headless 下载语言包 | ❌ | `canRequestDownloads = false`;`status = supported`(未装);`prepareTranslation()` 与 15 句 translate 全抛 `TranslationError.Cause.notInstalled` |
| 翻译质量(≥80% 看得懂) | ⏳ 未测 | 包未装,翻译未跑 |
| 延迟(终句→中文 <400ms) | ⏳ 未测 | 同上 |

**结论**:headless 翻译 API 可用,但**语言包必须走一次 UI 安装**(系统设置 → 通用 → 语言与地区 → 翻译语言 → 加中文(简体);或 SwiftUI `.translationTask` 弹系统 sheet)。裸后台进程无法自助下载 → 落进 spec §7"引导用户装一次"。**非 kill**。质量/延迟待装包后用同一二进制复测。

**运行原始输出(节选)**:
```
[1] LanguageAvailability status(en→zh-Hans): supported
[2] headless init 成功;canRequestDownloads = false
[3] prepareTranslation() 抛错: ...Cause.notInstalled
[4] 15 句全部 => notInstalled
[5] 成功 0 / 失败 15 / 共 15
```

**下一步**:用户装 en→中文(简体)语言包 → 重跑 `/tmp/p2` → 记质量抽样 + 逐句延迟。

---

## P1 [KILL] — SpeechAnalyzer / SpeechTranscriber

**状态:🟡 冒烟通过(管道/机制/自装模型 OK);准确率与实时延迟待真人 WAV + 实时喂入版复测**

探针:`probes/p1_transcribe.swift`;样本:`say` 生成 17.4s 英文(干净美音,**非口音测**)

| 断言 | 结果 | 证据 |
|---|---|---|
| API 在 CLT SDK 存在 | ✅ | `SpeechTranscriber`/`SpeechAnalyzer`/`analyzeSequence(from:)`;编译零报错 |
| **headless 下 en-US 模型** | ✅ | `AssetInventory.assetInstallationRequest(...).downloadAndInstall()` 15.0s 装好(**与 Translation 不同,Speech 可程序化下载**) |
| 识别跑通 | ✅ | 6 终句,输出成句 |
| 中间态/终句机制 | ✅ | 58 volatile + 6 final,`isFinal` 正确区分 |
| 处理速度 | ✅ | 17.4s 音频 0.53s 处理完(批处理 ~33× 实时) |
| 准确率(WER<15%) | ✅ 真人语音达标 | **真人 Harvard Sentences(8kHz 电话音质):美音 WER≈3-4%、英音≈2-3%**,仅零星单词级小错(parked→park、rare dish→reddish)。之前合成音的错是 say 嗓音+口述数字所致,非模型问题 |
| 口音鲁棒性(美/英) | ✅ | 美音、英音真人朗读均稳;印度等更重口音仍待样本 |
| **实时首字延迟(<300ms)** | ⏳ 待 P1b | 本探针批处理喂文件,时间戳非实时延迟;P1b 按实时节奏喂 buffer 测 |

**真人 WAV 复测(2026-07-07,Open Speech Repository,Harvard List 1,8kHz)**:美音 33.6s / 英音 40s,识别近乎逐句正确(见上)。**电话音质仍准 → 对电话场景是强信号。**

**结论**:管道、中间态/终句机制、模型自装均验通;**Speech 模型可 headless 下载是重要利好**。但**准确率与实时延迟的真正 go/no-go 未定**——需 (1) 真人(含口音)英文 WAV,(2) 按实时节奏用 `AnalyzerInput(buffer:)` 流式喂入的进阶探针测首字延迟。

**下一步**:写实时流式喂入版 P1b + 备真人 WAV → 测首字延迟 + 真实 WER。→ 已完成,见 P1b。

---

## P1b [KILL 延迟维度] — 实时流式喂入,测真实字幕滞后

**状态:🟡 关键发现——原文实时,但"终句定稿"滞后 ~3s → 触发翻译的设计需调整**

探针:`probes/p1b_realtime.swift`(按 1× 实时节奏喂 0.1s Int16 块;lag = 结果到达墙钟 − `result.range.end` 音频时刻)。样本:美音 real_us.wav 33.6s。
注:analyzer 目标格式实测 = **16000Hz / 1ch / Int16 交织**(commonFormat=3),需 `AVAudioConverter` 从源格式转换(印证 spec §3 FormatConverter 环节必需)。

| 指标 | 实测 | 判定 |
|---|---|---|
| 首个中间态(灰字/原文)滞后 | **0.104s** | ✅ 远优于 <300ms,原文近实时 |
| 终句定稿滞后 | **min 1.58s / 中位 3.12s / max 4.72s** | ⚠️ 流式 ASR 固有:final 等稳定确认 |

**关键连锁后果**:spec 原设计"终句定稿再触发翻译" → 译文 = 终句滞后(~3s)+ 翻译(~0.4s)≈ **3.4s**,**超 §1 端到端 <1s 目标**。

**P1c 拆解(`probes/p1c_stabilization.swift`,修正上面的初步判断)**:
- 对每个 final 找最早"文本与 final 一致"的 volatile,量"白等"= 盖章 − 稳定。
- 结果:**中位 0.04s / max 4.15s**——仅第一句白等 4s,其余 8 句几乎为 0。
- 含义:~3s 主要花在 **volatile 逐步收敛**(首残词 0.1s 冒,整句正确要到接近盖章),**不是"正确文本干等确认"**。
- **故"在稳定 volatile 上就翻译能省 3s"不成立**(至少这批数据):那样是翻译仍在变的文本→重刷,且省的量不稳定。

**杠杆① `.fastResults`(GitHub 线索 → 本机实测,2026-07-07)**:
`reportingOptions: [.volatileResults, .fastResults]` 后重测:
| | 终句滞后中位 | max |
|---|---|---|
| 仅 volatileResults | 3.12s | 4.72s |
| **+ .fastResults** | **1.70s** | 2.18s |
→ **几乎砍半**。首中间态仍 ~0。现实更新:**英文瞬时,中文 ≈ 1.7s + 翻译 0.4s ≈ 2s 出**。

**设计影响(部分缓解,仍有余量可挖)**:
1. **默认开 `.fastResults`**(已验证有效)。译文比原文慢 ~2s(而非 3.4s)。
2. ~~在稳定中间态上就翻译~~ —— 数据不支持能稳定省延迟。
3. **待试杠杆**:`SpeechAnalyzer.finalize(through:)` 主动逼停;真实连续对话语速下的滞后分布;参考 himomohi/AirTranslate 等 repo 的翻译触发时机。→ 实现期"延迟调优 spike"。

**GitHub 参考项目**(同类实时转写/翻译,值得挖):himomohi/AirTranslate(语音→翻译,最像)、yohasebe/speechdock、richlira/MeetingMindAI、FluidInference/swift-scribe、mozilla-mobile/firefox-ios(QuickAnswersKit)、rryam/AuralKit。

## P3 [DEGRADE] — ScreenCaptureKit 纯系统音频 + 授权

**状态:🟢 通过 — 采集成立;实测系统音频格式 48k/2ch/Float32(坐实 FormatConverter 参数)**

探针:`probes/p3_syscapture/`(SCStream capturesAudio + SCStreamOutput)

| 检查 | 结果 |
|---|---|
| 纯系统音频采集(无视频) | ✅ 6s 内 303 次音频回调,累计 6.06s |
| 拿到非静音 PCM | ✅ 峰值 1.0(捕获后台 afplay 的独立进程声) |
| **系统音频真实格式** | **48000Hz / 2ch / Float32** —— 与 analyzer 目标 16k/1ch/Int16 不同 → **FormatConverter 必做 48k→16k + 立体声→单 + Float→Int16** |
| excludesCurrentProcessAudio | ✅ 生效(排除 app 自身,防回环) |
| 屏录 TCC | ⚠️ ad-hoc /tmp app(`open` 启动)被 -3801 直接拒、不弹框、不进列表;**编成普通可执行直接跑则继承已授权宿主(Claude)成功**。真 app 需自己的标准屏录授权(参考项目通行做法) |

**结论**:系统音内录 + 格式转换路径打通。授权对"探针"别扭,对正常签名 app 是标准流程。**ScreenCaptureKit 路径可用,Process Tap 备选可不急**。

## P4 [DEGRADE] — AVAudioEngine mic + VoiceProcessing 回声

**状态:🟡 API 验通(VP 可开、格式已知);实际采集+回声留真前台 app**

探针:`probes/p4_mic_vp.swift` + `probes/p4_mic_vp/build.sh`

| 检查 | 结果 |
|---|---|
| 麦克风授权流程 | ✅ `.app`(带 `NSMicrophoneUsageDescription`)+ `open` 标准弹框授权成功 |
| `setVoiceProcessingEnabled(true)` | ✅ 成功(AEC/降噪可开) |
| **VP 下麦克风格式** | **24000Hz / 3ch / Float32** —— 与系统音(48k/2ch)不同 → FormatConverter 两轨各自转到 16k/1ch/Int16 |
| 实际采集样本 | ⚠️ 0 样本(探针环境限制:`open` 后台 app 不派发实时麦克风;直接跑被宿主缓存 TCC 拒绝、需重启)。**非框架问题**,真前台 app 可采(参考项目通行) |
| 回声消除干净度 | ⏳ 声学手测(需外放+人说话);**戴耳机=0 回声,PRD 已列为最稳路径** |

**结论**:VP API 通、格式明确。实际采集与回声消除留 Phase 1+ 真前台 app 验(DEGRADE,不阻塞)。

---

## 免权限+权限探针 总收尾(2026-07-07)

| 探针 | 类别 | 结果 |
|---|---|---|
| P1 识别准确 | KILL | 🟢 真人美/英音 WER 2–4% |
| P1b 实时延迟 | KILL | 🟡→缓解 原文实时,终句 `.fastResults` 后 1.7s |
| P2 翻译 | KILL | 🟢 headless 可用,40–130ms,~80% 懂 |
| P5a 双 analyzer 并发 | KILL | 🟢 真并行不互扰 |
| P3 系统音内录 | DEGRADE | 🟢 48k/2ch/Float32 采集通 |
| P4 mic+VP | DEGRADE | 🟡 VP 可开、24k/3ch;采集+回声留真 app |
| P5b 双轨真采集+热 | KILL/DEG | ⬜ 留 Phase 1+ 真 app |

**总结论:全本地方案 KILL 闸门全绿,方案成立。** 实测确定的关键工程事实:
- 音频格式三处不同:**系统音 48k/2ch/Float32、mic+VP 24k/3ch/Float32 → 统一转 analyzer 的 16k/1ch/Int16**(FormatConverter 是硬需求)。
- Speech 模型 headless 可下;Translation 语言包需一次性 UI 装。
- `.fastResults` 把译文滞后从 ~3.4s 压到 ~2s。
- 延迟现实:英文 ~100ms 实时,中文 ≈ 2s 追随。

## P5a [KILL 结构维度] — 双 SpeechAnalyzer 并发

**状态:🟢 通过 — 双 analyzer 真并行、不互扰(清掉 M1 结构性 KILL 疑点)**

探针:`probes/p5a_dual_analyzer.swift`(两个 transcriber+analyzer 同喂美/英文件,免权限)

| 检查 | 结果 |
|---|---|
| 双 analyzer 能否并发实例化+运行 | ✅ 无错,各出 10 终句 |
| 真并行 | ✅ 并发总墙钟 0.735s ≈ max(0.68,0.73),非 sum(~1.4s) |
| 是否串轨/交叉污染 | ✅ 无(两文件同为 Harvard List1,前缀相同属正常;各自内容正确) |
| 备注 | `文本==基线` 为 false 是 ASR 逐次微小不确定性(终句数一致),非并发干扰 |

**结论**:架构"两条独立 Task 各带一 analyzer"的双轨设计成立。**待补**:真双轨(mic+系统音实时源)下的持续负载/热,需 .app + 权限。

---

## P5b [DEGRADE] — 双轨真采集 + VP+SCK 共存 + 长时热
状态:⬜ 需 .app bundle + 麦克风/屏录授权(CLI 测不了)

---

## P3a 双 SpeechAnalyzer 并发 — 活体复验(2026-07-09,Phase 2)

`probes/p3a_dual_analyzer.swift`,喂 `/tmp/real_us.wav`(美)+ `/tmp/real_uk.wav`(英)到两个独立 `SpeechAnalyzer`(async let 并发):
- A 终句=9,B 终句=10,内容均正确。
- 并发耗时 **41.99s**(音频约 40s @1× 实时)→ 两路真并行,非串行(串行应 ~80s)。
- **✅ GO:双轨方案的核心架构风险(两分析器并发)确认成立。** 与 Phase 0 的 P5a🟢 一致。

## P3b VoiceProcessing AEC — 结论:改在 Task 5 端到端验(2026-07-09)

按 Phase 0 已记事实,回声/AEC 需带 entitlements 的 .app bundle + 麦克风/屏录 TCC,**纯 CLI 探针测不了真实声学回声**。因此不单跑 headless p3b,改为:
- MicSource 直接实现 `setVoiceProcessingEnabled(true)`(Task 1),AEC 效力在 **Task 5 端到端手测**里验(那步本就要麦克风+屏录授权)。
- 失败预案已在 spec:外放 AEC 不足 → 耳机兜底 / 提示。此预案不改 Task 1-4 的代码结构,故**代码任务可先推进**。

## Phase 2 端到端(2026-07-09)

真机测双轨:
- ✅ **对方轨**(系统音):正常出英文原文 + 中文(橙)。
- ✅ **我轨**(麦克风):修 ch0 bug 后正常出真实英文 + 中文(蓝)。日志实测 `outPeak` 700–4600、`event[me]` 出连续英文终句。
  - **踩坑 & 修复(commit dd58a9e):** VoiceProcessing 的麦克风输入是**多声道**(实测 7、9 路,数量每次还变 = mic + 参考/AEC 声道)。`FormatConverter` 的 `AVAudioConverter` 整组下混到单声道 → **全静音**(outPeak=0),尽管 ch0 有健康人声(ch0peak 0.02–0.31)。改成**显式取 0 声道**(即 AEC 处理后的近端麦克风)再转换后正常。诊断用 `probes/p3c_mic_format.swift` + 临时文件日志定位。
- ✅ **防闪烁**:真机埋点实测 volatile 中间态仅 0–6 次/2s(远低于 16 次/2s 上屏上限),节流够用,不抖。
- ❌→决策 **AEC / VoiceProcessing:关闭(2026-07-09,推翻 spec 的"AEC 用 VoiceProcessing")**。真机 + GitHub 调研(resound/Queen_Mama/Parrot 同结论)证实 VP 对本双轨方案纯亏:
  - VP 麦克风输入是多声道(7/9 路且会变),下混致静音(已靠取 ch0 绕过,但脆弱)
  - VP **压低扬声器输出**(用户实测"喇叭变小声")
  - VP **掐 ScreenCaptureKit 系统音轨**(Queen_Mama 实测 SCK 采对方近静音)
  - VP **并不能消掉别的 app 从扬声器放出的对方声**(外放漏音照旧)
  - → 改为麦克风裸采集(commit 8c64e8b)。**外放漏音(对方被麦克风收进变蓝色「我」)= 已知限制,通话戴耳机解决**(用户确认接受)。
  - 未来若要治外放:用手里已有的 SCK 对方信号做轻量能量门限,或上 WebRTC AEC3(重,不选)。

## 免权限探针小结(2026-07-07)

**能在 CLT/CLI 下验的 KILL 项全部跑完:**
- P2 翻译 🟢 · P1 识别准确 🟢 · P1b 实时延迟 🟡(终句滞后~3s,设计需调)· P5a 双 analyzer 并发 🟢
- **全本地方案在机制/质量/并发层站得住,无 KILL 崩。**

**剩余探针(P3 内录 / P4 回声 / P5b 双轨真采集)均需带 entitlements 的 .app bundle + TCC 授权**,CLI 无法覆盖 → 绕回"构建方式"决策(见 spec §9)。

## P6a [KILL] — FluidAudio 声纹 embedding(2026-08-14,Phase 6)

**探针:** `probes/p6a_voiceprint/`(独立 SwiftPM 包,FluidAudio 依赖只进这里,主 Package.swift 未动)
**解析版本:** FluidAudio **0.15.5**(plan 写的 0.12.4 是下限;API 已按 0.15.5 真实源码核对)

### Step 1 装包闭环 —— ✅ 通过(2026-08-14 实测)

- 模型自动下载至 `~/Library/Application Support/FluidAudio/Models`:
  `pyannote_segmentation.mlmodelc` 5.5 MB + `wespeaker_v2.mlmodelc` 7.7 MB。
  首次 download+编译 19.2s;后续 wespeaker 单独加载 **0.07s**。
- **spec 未决 1 已答:✅ 可以只加载 embedding 模型、完全跳过 segmentation。**
  真实 API 与 plan 的推测不同:0.15.5 已有现成的
  `DiarizerManager.extractSpeakerEmbedding(from:) -> [Float]`(单说话人整段音频,
  内部全 1 mask,**不跑 segmentation 推理**,只读其输出形状拿 mask 帧数)。
  更轻的路线:`EmbeddingExtractor(embeddingModel:)` 直接用单个 MLModel 构造,
  mask 帧数可从 **embedding 模型自己的输入形状**读出(589 帧/10s 窗),
  两条路径对同一音频的 embedding **余弦 = 1.000000**。
  → **Task 5 按轻量路线写:只载 wespeaker_v2,内存/加载时间估算大幅好于 spec 的保守假设。**
- 推理耗时:首次(模型热身)3.1s,**热后 49ms/次**(3s 音频,release,M 系)。
  spec 预估 <50ms —— 热后成立;Task 5 要做**启动预热**把首次 3s 藏掉。
- ⚠️ **发现:embedding 输出并非严格 L2 归一化**(3s 合成音实测 L2=1.037)。
  spec/plan 写「FluidAudio 的输出即是 L2 归一化」不成立(FluidAudio 自己入库前也会再 normalize)。
  → **Task 5 的 `VoiceprintExtractor` 实现必须自己做 L2 归一化后再交给 SpeakerClusterer**
  (clusterer 的 cosine 是纯点积,吃未归一化向量会整体偏移阈值)。plan 已改。

### Step 2/3/4 —— ⏳ 待人工样本

工具已就绪(`swift run -c release p6a <matrix|decay|embed>`),等录音:
- **me_zh_1..5、me_en_1..5**(本人中/英各 5 段,每段 ≥20s)
- **<他人>_zh_*、<他人>_en_***(2–3 人,家人/同事/播客片段皆可)
- 命名 `<人>_<语言>_<序号>.<wav|m4a|mp3>`,放一个目录跑 `matrix`,
  输出全对余弦 + 同人/异人分组统计 + θ_me/θ_cluster 建议区间
- `decay` 用任一 ≥6s 样本出 0.5/1/2/3/5s 前缀衰减曲线,校 spec §2 的 1.0s 短句阈值

### Step 2/3/4 区分度实测 —— ✅ GO(2026-08-14)

**样本:** 本人 me_zh×5(22–25s)+ me_en×5(29–38s,QuickTime 内置麦);
异人 = LibriVox 公有领域录音剪辑(中文 4 人:感恩节纪实/虬髯客传/孙子兵法/水调歌头;
英文 3 人:傲慢与偏见 Karen Savage/福尔摩斯冒险史/孙子兵法英译),每人 2 段 ×30s,
`p6a trim` 统一转 16k 单声道。共 24 样本。

**分组余弦(24×24 全对):**

| 组 | n | min | 中位 | max |
|---|---|---|---|---|
| zh 同人 | 14 | 0.721 | 0.886 | 0.930 |
| zh 异人 | 64 | 0.040 | 0.191 | **0.353** |
| en 同人 | 13 | 0.643 | 0.852 | 0.896 |
| en 异人 | 42 | −0.019 | 0.094 | **0.238** |

**判定:zh 间隔 +0.368、en 间隔 +0.405,两簇完全不重叠 → 🟢 GO,WeSpeaker 够用,CAM++ 对冲不启用。**
spec 担心的「中文判别力偏低」未出现 —— 中文同人一致性(中位 0.886)甚至优于英文(0.852)。

**θ 定值(写回 spec §2,替代占位的 0.75/0.70):**
- **θ_me = 0.70,θ_cluster = 0.60**(保持 θ_me > θ_cluster 不对称)。
  探针公式给的 0.57/0.46 偏激进,不取 —— 见下方 caveat;实测同人 min 0.72/0.64、
  异人 max 0.35/0.24,0.70/0.60 在两簇之间留了双向余量,且对短句衰减(见下)有容忍度。
- ⚠️ **Caveat:异人样本是有声书录音,信道(麦克风/编解码)与本人样本不同,
  信道差异会人为拉大异人距离** —— 异人 max 0.35 可能偏乐观。因此阈值取保守高位,
  真机多人会议(Task 10)再校。两个阈值都在设置页可调。

**Step 4 短音频衰减(静音修剪后,同段前缀 vs 整段):**

| 前缀 | zh | en |
|---|---|---|
| 0.5s | 0.350 | 0.614 |
| 1.0s | 0.614 | 0.736 |
| 2.0s | 0.826 | 0.885 |
| 3.0s | 0.905 | 0.917 |

**→ spec §2 短句兜底阈值由 1.0s 上调为 2.0s**(1s 的 embedding 余弦已落进阈值危险区,
2s 起才稳定在 0.83+)。`SpeakerAttributor.minDuration = 2.0`。
另:探针 decay 初版没剪录音起头的静音,测出过 1s→0.097 的假衰减 —— 已修
(能量门限找语音起点),将来任何用短音频的分析都要先修剪静音。

## P7 [KILL] — SpeechTranscriber zh-CN(2026-08-14,Phase 6)—— ✅ GO

**探针:** `probes/p7_zh_transcribe.swift`(swiftc 单文件,沿用 P1 模式)

- **[1] supportedLocales 共 45 个,含 `zh_CN` / `zh_HK` / `zh_TW` / `yue_CN`** → 中文会议路线成立,Task 7 存活
- **[2] `AssetInventory.status(zh_CN)` = supported,无需下载**(本机中文语音资产已就绪;
  headless 安装路径与 P1 英文同构,未触发即通过)
- **[3] 识别抽样(me_zh_1,24.5s 朗读):** 中间态 106 条 / 终句 2 条,首终句 @0.61s(批处理)。
  与朗读文本人工比对:主体正确,同音错字若干(城西→城市、淘到几本→他到基本、愿意→月影、
  搬了→办了),标点断句正常,**估计字准 ~90%,对会议字幕可用**。
  实时终句滞后(对照 P1b 英文 1.70s 中位)留待真机会议实测,不阻塞。
- **顺带解掉 plan Task 6 的 🔴「audioTimeRange 取法」:`SpeechTranscriber.Result.range`
  是非可选 `CMTimeRange`,直接可用,无需从 attributed runs 里挖属性。**
  实测两条终句 range = 1.86–19.68s / 19.68–24.53s,起点与录音开头 1.9s 静音吻合
  —— analyzer 时间轴与样本序号对齐的假设成立(环形缓冲设计成立)。

**结论:P7 🟢 GO。Task 7(会议语种开关)照 plan 做;三个 KILL 闸门(P6a/P7)全部通过,
剩 P6b 负载探针(DEGRADE)与 Task 10 真机验收合并跑。**

### P6c 阈值复核:注册档案(多窗平均)vs 会话短句 —— ⚠️ θ 需下调(2026-08-15)

**动因(Task 8 评审提出):** P6a 的 θ_me=0.70 / θ_cluster=0.60 是拿**整段 vs 整段**标定的
(且当时未察觉 FluidAudio 内部只取前 10s,实际是「前 10s vs 前 10s」)。
但真实链路是 **多窗平均的注册档案 × 会话里一条几秒的终句** —— 这个组合从没测过。
探针 `p6a enrollcheck` 复现 Task 8 `VoiceprintEnrollment` 的数学(切 10s 窗 → 逐窗 embed →
求和 → L2 归一化),对 24 个样本、按会话句长 3s/5s/10s 三档量分布。

| 会话句长 | 同人 min | 同人中位 | 异人 max | 间隔 |
|---|---|---|---|---|
| 3s | **0.485** | 0.832 | 0.410 | +0.075 |
| 5s | **0.677** | 0.878 | 0.405 | +0.272 |
| 10s | **0.710** | 0.923 | 0.417 | +0.293 |

**两个与 P6a 不同的结论:**

1. **θ_me = 0.70 对短句过严,方向是「漏判我」而非「误判成我」。**
   5s 句的同人 min 已经 0.677 < 0.70 → 自己说的话会被判成「不是我」,转而新建/归入
   聚类簇,显示成「说话人 N」。而异人 max 在三档都稳定在 0.40–0.42,
   **下调空间很大**。定值改为 **θ_me = 0.60、θ_cluster = 0.50**
   (仍保持 θ_me > θ_cluster 的不对称;距异人 max 0.42 留 0.18 余量,
   距 5s 同人 min 0.677 留 0.077 余量)。
2. **短句兜底 2.0s 太宽松,上调为 4.0s。** 3s 档的间隔只剩 +0.075,判定已不可靠;
   5s 档才回到 +0.272。低于 4s 的终句走「沿用该轨上一句身份」的连续性启发式,
   比拿一个不可靠的向量去猜更安全。

**caveat 依旧:** 异人样本是有声书信道,真实会议中同信道异人的余弦可能高于 0.42。
θ_me=0.60 留的 0.18 余量正是为此;Task 10 真机多人会议要复核这条,
两个阈值设置页可调(Task 8 未做可调 UI,留 Task 10 后按需补)。

## P6d [标定] — 短句判定的时长下限重标(2026-08-15,Task 10 实测触发)

**为什么要重标:** Task 10 真机跑一段 YouTube(两个说话人),诊断日志显示 **18 条终句里只有 4 条够 4.0s**
—— 78% 的行走的是「沿用上一句身份」而非真判定,用户主观感受是「声纹压根没启用」。
而同一份日志里簇内余弦 0.708–0.760、簇间 **−0.023**,间隔大得离谱,说明 4.0s 这个下限过保守了。
P6c 只测了 3s/5s/10s 且只测了「注册档案」那条路,这里把两条路都往短里扫。

**方法**(`swift run -c release p6a shortcheck samples/`):9 组(人 × 语言),每组第 1 个 clip 建
【注册档案】(多窗平均)与【簇心】(5s 窗 ×3,滑动平均 + 重归一化,与 `SpeakerClusterer.update` 同一套数学),
其余 clip 出测试短句 —— **建心与测试用不同 clip,不自我匹配**。只在同语言内比对(用户约束)。
同人 n=33、异人 n=117。

### 硬错全程为 0 —— 这是本次标定的核心结论

异人余弦最高只到 **0.404**(2.5s 档),在任何句长下都够不着 θ_cluster=0.50,更够不着 θ_me=0.60。
**降低时长下限不会「把别人认成我」,也不会「把两个人并成一个」。** 代价只有软错:

| 句长 | θ_cluster 同人被拆 | θ_me 漏判自己 | 硬错 |
|---|---|---|---|
| 5.0s | 0/33 | 0/33 | 0/117 |
| 4.0s(原定值) | 0/33 | 0/33 | 0/117 |
| 3.0s | 1/33 | 1/33 | 0/117 |
| **2.0s(新定值)** | **2/33 (6%)** | **5/33 (15%)** | **0/117** |
| 1.5s | 5/33 (15%) | 11/33 (33%) | 0/117 |
| 1.0s | 12/33 (36%) | 19/33 (58%) | 0/117 |

同人余弦中位数随句长的变化(路径 B / 簇心):1.0s 0.566 → 2.0s 0.690 → 3.0s 0.784 → 5.0s 0.849。

### ❌ 推翻:「两条路径该拆成两个下限」

标定前的假设是「判『我』比对的是 20s 朗读出来的注册档案,判簇比对的是几条短句攒的簇心,
两者分布不同,下限该拆开」。**数据否掉了它** —— 两条路径几乎重合(2.0s:同人中位 0.710 vs 0.690,
异人 max 0.374 vs 0.372)。拆开不但没收益,还有害:只放宽簇路径会让【你自己】2–4 秒的句子
跳过「我」的比对直接进簇,被标成「说话人 N」,比不拆更糟。**结论:单一 minDuration。**

### 定值

**minDuration 4.0s → 2.0s**,并放进设置页可调(1.0–6.0,步长 0.5)。
理由:覆盖率 22% → 约 33%,硬错 0,软错 6%;而现状那 78% 的「沿用上一句身份」在说话人频繁轮换时
(真机日志里就是)错误率大概率高于 6%。θ_me / θ_cluster 维持 P6c 的 0.60 / 0.50 不动 —— 本次数据
显示它们在 2.0s 档仍有充足余量(异人 max 0.374)。

**样本局限**(别把这几个数当普适结论):9 组均为朗读语料、无背景噪声、无抢话;真机视频里的
压制音频、背景音乐、混响都没进标定集。设置页那根滑杆存在的意义就是让真实场景能自己找值。
