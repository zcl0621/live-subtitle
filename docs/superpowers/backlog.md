# LiveSubtitle Backlog(后续 phase 需求捕获)

> 记录已确认、但排在当前 phase 之后的需求。轮到时各自走 brainstorm→spec→plan。

## Phase 4 — 字幕条可操作 + 权限前置 ✅ 代码已实现(2026-07-13,branch phase4-5-perms-bar-obsidian)

- ✅ **字幕条(bar)可调**:"布局编辑"开关 → bar 变可交互 + 可拖(关闭恢复点击穿透);位置存 `ls.barX/Y`;宽度用滑块(`store.barWidth`,600–1400)。
- ✅ **小窗缩放**:mini panel 原生 `.resizable`,内容自适应,尺寸存 `ls.miniW/miniH`。
- ❌ **「开 app 即请求权限」已撤销**(2026-07-30):改为**点「开始字幕」时**才调 `PermissionsManager.requestAll()`。启动阶段拉起 TCC 授权流程与菜单栏图标问题纠缠不清,且点用时请求本就是 macOS 惯例。
- ✅ **真机验证通过**(2026-07-30 用户手测):bar 拖动/宽度、mini 缩放、控制面板、导出、设置页均正常。
- (原计划遗留,仍 deferred)回声/外放漏音兜底(**已决策:关 VoiceProcessing + 耳机**,见 probes/RESULTS.md)、音频路由变化处理、延迟调优 spike。

## Phase 5(新子系统)— Obsidian 导出 + DeepSeek 总结 + 设置页 ✅ 代码已实现(2026-07-13)

**实现落点(2026-07-13):**

- ✅ **Obsidian 导出** `Export/ObsidianExporter.swift`:写 `<yyyy-MM-dd>-<title>.md`(frontmatter title/date/tags/source + `## 总结` + `## 转录`),vault 目录不存在则 throw。转录只收 `isFinal` 行,格式 `- **我/对方**:原文 — 译文`。
- ✅ **DeepSeek** `Export/DeepSeekClient.swift`:POST `api.deepseek.com/chat/completions`,model `deepseek-chat`,`response_format=json_object`,解析 `{title,summary}`。
- ✅ **编排** `Export/ExportCoordinator.swift`:取终句 → 有 key 调 DeepSeek(失败/无 key 回退默认标题 + 占位 summary,**仍导出**)→ `Task.detached` 写盘。菜单按钮"整理并导出到 Obsidian"触发,状态显示在菜单。**手动触发**(尊重"主动导出才上云"的隐私边界)。
- ✅ **设置页** `Overlay/SettingsView.swift` + App `Settings` scene(菜单"设置…"用 `openSettings()` 打开):`SecureField` 配 DeepSeek key、`NSOpenPanel` 选 vault 目录。
- ⚠️ **API key 存 UserDefaults 明文**(自用可接受;未来上架/沙盒 → Keychain)。
- ✅ **真机验证通过**(2026-07-30 用户手测):设置页、选 vault 目录、导出流程均正常。

**已定决策(2026-07-09 与用户确认):**

- **Obsidian 集成 = 直接写 .md 文件,不用 MCP。** vault 本质是 markdown 文件夹;设置里用 `NSOpenPanel` 让用户选 vault 路径(或子文件夹),app 写 `<日期>-<title>.md`。Obsidian 没开也能写、零依赖、离线。(以后若上架沙盒 → security-scoped bookmark。)
- **DeepSeek 集成 = 云 API(OpenAI 兼容),设置页配 API key。** 事后对转录做**总结 + 优化 + 自动生成 title**。**不做 link**(用户明确不要)。
- **隐私边界(用户认可):** 实时字幕链路 **100% 保持本地**(STT + 翻译不变);**只有"主动导出整理进 Obsidian"这一步**把转录发 DeepSeek 云。可选:总结那步也能换本地 LLM(Ollama/Apple 基础模型),但当前按 DeepSeek 做。
- **设置页**:至少含 DeepSeek API key、Obsidian vault 路径。
- 笔记内容形态待细化:frontmatter(title/date/tags/来源)+ 转录(对方/我)+ DeepSeek 总结段。导出触发时机(停止字幕后?手动按钮?)待 brainstorm。

## Phase 6(新子系统)— 声纹说话人识别 ✅ 代码已合入(2026-08-15)⚠️ **会议场景未验收**

> **合入时的诚实状态**:Task 1–10 的代码全部落地、188 单测全绿、真机跑过 YouTube 视频与本人麦克风
> 两类场景并据此修了 4 个真 bug;但**没有跑过任何一场真实会议**(用户当时没有会议可测),
> P6b 负载也只有零头数据。合入是因为主链路(字幕/翻译/导出)不受影响、声纹出问题只退化成
> 标签不准,不阻塞日常使用。**下次开会时按 plan 的 Task 10 清单补验**,尤其是簇爆炸与长会话内存。

**问题:** 现在 `Speaker = { me, other }` 等价于「麦克风轨 / 系统音轨」,但**两条轨都可能有多人**(会议室里同事、远端多个参会者)。

**已定决策(2026-08-10 与用户确认):**

- **选型 = [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio)**(Apache-2.0,纯 Swift + CoreML 走 ANE,macOS 14+)。**不接三方云**。
- **只用 `extractEmbedding()`,不跑完整 diarization。** 终句自带 `audioTimeRange`(现有 pipeline 已开该 attribute),直接切那段音频抽一个声纹向量即可 —— 省 segmentation 算力,且天然与字幕行对齐,不需要「时间线 → 句子」映射。代价:句内抢话整句归一人(已接受)。
- **用户约束:不跨语言匹配;「我」的声纹中英各录一份;一个会议只有一种语言;中文会议不翻译。**
  - → 这消除了跨语言 drift 问题,**sherpa-onnx + CAM++ 中英模型的备选方案因此否决**(其唯一优势就是跨语言鲁棒,代价是引 onnxruntime + C++ 依赖)。
  - → 也**顺带把 ASR 语种缺陷降级**:不用 code-switching / 4 个 analyzer,只要一个会话级语种开关(现状 `SpeechTranscriber` 写死 `en-US`,中文会议会出乱码)。
- **Apple 原生无 diarization** —— `SpeechAnalyzer` 只有 `SpeechTranscriber`/`DictationTranscriber`/`SpeechDetector`,确认没有说话人分离模块。
- **关键架构切分:`Speaker` 按职责一分为二** —— `Track { mic, system }`(路由用,承接旧枚举在「每轨状态字典键」上的角色,值域仍是 2、逻辑不动)+ `SpeakerID`(显示用,带 me/cluster/unresolved)。中间态按轨占位、终句按声纹回填(复用 `attachTranslation` 的回填模式)。**这个切分把重构面从「8 个源文件全改」压到「只有 `SubtitleLine.speaker` 升级」。**
- **架构对冲:** 抽 embedding 放 `VoiceprintExtractor` protocol 后面。FluidAudio 用的是 WeSpeaker ResNet34-LM(VoxCeleb 英文训练),**中文判别力是已知残留风险**,若 P6a 实测不合格,换 CAM++ 只动一个实现类。

**前置 KILL 闸门(已跑完):**

- **P6a** FluidAudio 中英区分度 + 阈值标定 → 🟢 **GO**(2026-08-14):WeSpeaker 够用,CAM++ 对冲不启用;embedding 需自行 L2 归一化。
- **P7** `SpeechTranscriber` zh-CN 支持与模型下载 → 🟢 **GO**(Task 7 因此存活)。
- **P6c** 阈值复核(2026-08-15,Task 8 评审提出)→ 推翻 P6a 的标定:真实链路是「多窗平均的注册档案 × 会话里一条几秒的终句」,同人余弦系统性偏低。**θ_me 0.70→0.60、θ_cluster 0.60→0.50、短句兜底 2.0s→4.0s**。这三个值现在也在设置页可调(默认即标定值,θ_me > θ_cluster 的不对称由代码守)。
- **P6b** 推理负载(DEGRADE 级)→ **仍未跑**,与 Task 10 一并留到真机阶段。

**落地状态(2026-08-15):**

- **Task 1–10 代码全部完成**,188 单测全绿。含:Track/SpeakerID 拆分、环形缓冲、在线聚类、档案持久化、FluidAudio 抽取器、SpeakerAttributor 接线、会议语种开关、声纹录制 UI + 说话人配色/改名、Obsidian 导出按会话分段。
- **真机跑过并据此修掉的 4 个真 bug**(全部是单测碰不到的):① 声纹录制点「录制」必崩(`@MainActor` 类里的 tap 闭包被推断成 MainActor 隔离,音频线程上触发执行器断言 SIGTRAP);② 4.0s 的判定下限把 78% 的终句挡在门外,主观表现为「声纹压根没启用」→ P6d 重标为 2.0s 并做成设置项;③ 被污染的单句凭空劈出新说话人 → 聚类加「死区」;④ 改名映射的作废时刻与导出锚点不同步 → 导出丢名字。
- ⚠️ **仍未验收:一场中文会议 + 一场英文会议**(合入时用户没有会议可测)。要重点看「簇爆炸」(同一人被拆成多个说话人)—— 缓解手段是设置页的 θ_cluster 滑杆 + 已就位的死区。
- ⚠️ **P6b 负载只有零头数据**(模型加载+预热 0.5–0.7s、单次判定 50–65ms),缺 10 分钟持续负载与热。
- 📌 **开发期提示**:ad-hoc 签名的 designated requirement 就是二进制 CDHash,每次重打包 TCC 授权即作废
  —— 表现为「反复弹权限框」,甚至出现过 `authorizationStatus` 报已授权但麦克风采不到数据。
  造一个固定的自签名证书可免除,做法见 `scripts/build-app.sh` 注释。

**接线参考:** [Marvinngg/ambient-voice](https://github.com/Marvinngg/ambient-voice)(MIT)—— 同技术栈(Apple SpeechAnalyzer + FluidAudio),可直接抄。

**顺带收益(注意别说过头):** 「我」不再等于麦克风轨后,外放漏音**被错标成蓝色「我」**这一半治好了 —— 对方的声音从喇叭漏进麦克风,声纹一比对就知道不是,标签会翻成「说话人 N」并与系统轨那句同簇同色。

⚠️ **但漏音本身没治,重复上屏也没治**(2026-08-15 真机实测撞到):两条轨仍各自识别同一段声音,同一句话上屏两遍;且判定只对【终句且 ≥4s】生效,中间态与短句仍走轨别名兜底,那一瞬间麦克风轨的漏音行照样显示「我」。**外放场景的唯一解仍是戴耳机**(与 Phase 4 的既定决策一致)。真要在软件里治,得做跨轨去重(麦克风终句与近期系统终句文本高度重合 → 丢弃),没排期。

> spec:`specs/2026-08-10-livesubtitle-phase6-voiceprint-design.md`
> plan:`plans/2026-08-10-livesubtitle-phase6-voiceprint.md`
> ⚠️ 两份文档均在无 Swift 工具链的 Linux 环境撰写,**代码零编译验证**;涉及 FluidAudio API 的部分签名取自其文档而非源码,首次 build 必然要修。文档内已逐处标注置信度。

## ⚠️ 形态变更:菜单栏 app → 普通窗口 app(2026-07-30)

PRD/Phase 3 原定"菜单栏驱动"(`MenuBarExtra`),**已改为普通窗口 app**。原因:

- 从 `/Applications` 经访达/LaunchServices 启动时,**菜单栏图标始终不出现**:AX 显示状态项已注册、app 事件循环正常、无崩溃、无任何日志输出,但就是不绘制;从 shell 直接起有时可见,从访达起不可见。
- 用最小 SwiftUI 测试 app 做过多轮二分(符号有效性、`.menu`/`.window` 样式、`Settings` 场景、`@NSApplicationDelegateAdaptor`、两项权限请求的组合、全新 bundle id 复现首次启动)。一度以为是"启动时同时请求麦克风+屏幕录制"所致,**该结论后被证伪**(去掉权限请求仍不显示)。
- **根因未查明**,故不再纠缠:改为 `WindowGroup` 控制面板窗口 + 去掉 `LSUIElement`。附带好处是有了 Dock 图标(`.icns` 派上用场)和标准 app 菜单(⌘Q/⌘,)。
- 字幕浮窗(bar/mini `NSPanel`)不受影响,仍是独立浮层。

> 若以后想回菜单栏形态:`MenuBarExtra` 相关代码见 commit `9db803f` 之前的版本;需先解决上述"状态项注册但不绘制"的问题。

## 状态(2026-07-30)

**Phase 3 + 4 + 5 全部完成并经用户真机验收**(功能正常),0 error / 31 XCTest 绿 / bundle 带图标。
分支 `phase4-5-perms-bar-obsidian`(基于 `phase3-overlay`)共 19 commits,待合入 `main`。
实现与后续变更明细见 `plans/2026-07-13-livesubtitle-phase4-5-impl.md`。

## 后续可做(未排期)

- **翻译上下文**:本地逐句翻译无上下文,代词/专名前后不一致——要破得上云 LLM,与"实时链路全本地"冲突,暂不做。
- **Keychain 存 API key**(替换 UserDefaults 明文),上架/沙盒化时必做。
- **显示器热插拔时重定位已显示浮窗**(监听 `didChangeScreenParametersNotification`)。
- **延迟调优 spike**:量化端到端延迟(spec §1 有 6 个指标),看边说边译开/关的实际差异。
- 音频路由变化处理(切换耳机/外放中途)。
