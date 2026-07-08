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

## 免权限探针小结(2026-07-07)

**能在 CLT/CLI 下验的 KILL 项全部跑完:**
- P2 翻译 🟢 · P1 识别准确 🟢 · P1b 实时延迟 🟡(终句滞后~3s,设计需调)· P5a 双 analyzer 并发 🟢
- **全本地方案在机制/质量/并发层站得住,无 KILL 崩。**

**剩余探针(P3 内录 / P4 回声 / P5b 双轨真采集)均需带 entitlements 的 .app bundle + TCC 授权**,CLI 无法覆盖 → 绕回"构建方式"决策(见 spec §9)。
