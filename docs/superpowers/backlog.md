# LiveSubtitle Backlog(后续 phase 需求捕获)

> 记录已确认、但排在当前 phase 之后的需求。轮到时各自走 brainstorm→spec→plan。

## Phase 4 — 字幕条可操作 + 权限前置

- **字幕条(bar)可调**:拖动换位置、缩放大小、调透明度(此前 opacity/字号已在 Phase 3 做;Phase 4 补 bar 的**拖拽 + 缩放**,以及小窗缩放)。
- **开 app 即请求权限**:启动时就请求 屏幕录制 + 系统音频录制授权(不等到点"开始字幕")。
- (原计划遗留)回声/外放漏音兜底、音频路由变化处理、延迟调优 spike。

## Phase 5(新子系统)— Obsidian 导出 + DeepSeek 总结 + 设置页

**已定决策(2026-07-09 与用户确认):**

- **Obsidian 集成 = 直接写 .md 文件,不用 MCP。** vault 本质是 markdown 文件夹;设置里用 `NSOpenPanel` 让用户选 vault 路径(或子文件夹),app 写 `<日期>-<title>.md`。Obsidian 没开也能写、零依赖、离线。(以后若上架沙盒 → security-scoped bookmark。)
- **DeepSeek 集成 = 云 API(OpenAI 兼容),设置页配 API key。** 事后对转录做**总结 + 优化 + 自动生成 title**。**不做 link**(用户明确不要)。
- **隐私边界(用户认可):** 实时字幕链路 **100% 保持本地**(STT + 翻译不变);**只有"主动导出整理进 Obsidian"这一步**把转录发 DeepSeek 云。可选:总结那步也能换本地 LLM(Ollama/Apple 基础模型),但当前按 DeepSeek 做。
- **设置页**:至少含 DeepSeek API key、Obsidian vault 路径。
- 笔记内容形态待细化:frontmatter(title/date/tags/来源)+ 转录(对方/我)+ DeepSeek 总结段。导出触发时机(停止字幕后?手动按钮?)待 brainstorm。

## 当前进行

- **Phase 3**:overlay 打磨(菜单栏控制:显示三态 / 字幕条⇄小窗 / Pin / 透明度 / 字号 / 持久化)——spec 已定,进 writing-plans。
