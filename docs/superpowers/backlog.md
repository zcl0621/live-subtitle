# LiveSubtitle Backlog(后续 phase 需求捕获)

> 记录已确认、但排在当前 phase 之后的需求。轮到时各自走 brainstorm→spec→plan。

## Phase 4 — 字幕条可操作 + 权限前置 ✅ 代码已实现(2026-07-13,branch phase4-5-perms-bar-obsidian)

- ✅ **字幕条(bar)可调**:菜单"布局编辑"开关 → bar 变可交互 + 可拖(关闭恢复点击穿透);位置存 `ls.barX/Y`;宽度用菜单滑条(`store.barWidth`,600–1400)。
- ✅ **小窗缩放**:mini panel 原生 `.resizable`,内容自适应,尺寸存 `ls.miniW/miniH`。
- ✅ **开 app 即请求权限**:`AppDelegate.applicationDidFinishLaunching` → `PermissionsManager.requestAllOnLaunch()`(麦克风 `AVCaptureDevice.requestAccess` + 屏幕录制 `CGRequestScreenCaptureAccess`)。**不是**挂菜单 `.task`(那要等点开菜单才触发)。
- ⏳ **待真机验证**:bar 拖动/宽度、mini 边缘缩放、启动权限框弹出时机(borderless panel 边缘缩放的手感尤其需要肉眼确认)。
- (原计划遗留,仍 deferred)回声/外放漏音兜底(**已决策:关 VoiceProcessing + 耳机**,见 probes/RESULTS.md)、音频路由变化处理、延迟调优 spike。

## Phase 5(新子系统)— Obsidian 导出 + DeepSeek 总结 + 设置页 ✅ 代码已实现(2026-07-13)

**实现落点(2026-07-13):**

- ✅ **Obsidian 导出** `Export/ObsidianExporter.swift`:写 `<yyyy-MM-dd>-<title>.md`(frontmatter title/date/tags/source + `## 总结` + `## 转录`),vault 目录不存在则 throw。转录只收 `isFinal` 行,格式 `- **我/对方**:原文 — 译文`。
- ✅ **DeepSeek** `Export/DeepSeekClient.swift`:POST `api.deepseek.com/chat/completions`,model `deepseek-chat`,`response_format=json_object`,解析 `{title,summary}`。
- ✅ **编排** `Export/ExportCoordinator.swift`:取终句 → 有 key 调 DeepSeek(失败/无 key 回退默认标题 + 占位 summary,**仍导出**)→ `Task.detached` 写盘。菜单按钮"整理并导出到 Obsidian"触发,状态显示在菜单。**手动触发**(尊重"主动导出才上云"的隐私边界)。
- ✅ **设置页** `Overlay/SettingsView.swift` + App `Settings` scene(菜单"设置…"用 `openSettings()` 打开):`SecureField` 配 DeepSeek key、`NSOpenPanel` 选 vault 目录。
- ⚠️ **API key 存 UserDefaults 明文**(自用可接受;未来上架/沙盒 → Keychain)。
- ⏳ **待真机验证**:设置页打开、选目录、真实 DeepSeek 调用 + 写出 .md(需你填真 key + 选 vault)。

**已定决策(2026-07-09 与用户确认):**

- **Obsidian 集成 = 直接写 .md 文件,不用 MCP。** vault 本质是 markdown 文件夹;设置里用 `NSOpenPanel` 让用户选 vault 路径(或子文件夹),app 写 `<日期>-<title>.md`。Obsidian 没开也能写、零依赖、离线。(以后若上架沙盒 → security-scoped bookmark。)
- **DeepSeek 集成 = 云 API(OpenAI 兼容),设置页配 API key。** 事后对转录做**总结 + 优化 + 自动生成 title**。**不做 link**(用户明确不要)。
- **隐私边界(用户认可):** 实时字幕链路 **100% 保持本地**(STT + 翻译不变);**只有"主动导出整理进 Obsidian"这一步**把转录发 DeepSeek 云。可选:总结那步也能换本地 LLM(Ollama/Apple 基础模型),但当前按 DeepSeek 做。
- **设置页**:至少含 DeepSeek API key、Obsidian vault 路径。
- 笔记内容形态待细化:frontmatter(title/date/tags/来源)+ 转录(对方/我)+ DeepSeek 总结段。导出触发时机(停止字幕后?手动按钮?)待 brainstorm。

## 当前进行 / 状态(2026-07-13)

- **Phase 3**(branch `phase3-overlay`,5 commits,18→19 测试绿):代码完成;**Task 6 真机手测仍未做**(你的活)。未合并 main。
- **Phase 4 + 5**(branch `phase4-5-perms-bar-obsidian`,基于 phase3-overlay,6 commits,19 测试绿,bundle OK):代码完成、编译测试通过;**真机手测未做**。未合并 main。
- **待你决定**:①Phase 3/4/5 真机验收顺序;②验收 OK 后如何合 main(整条 stack 合,还是逐 phase)。
