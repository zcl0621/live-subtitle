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
