# LiveSubtitle Phase 4 + 5 — 实现记录(2026-07-13)

> 决策已在 `backlog.md` 拍板(2026-07-09),本次直接实现,未再走完整 brainstorm/spec。
> branch `phase4-5-perms-bar-obsidian`(基于未合并的 `phase3-overlay`)。多 subagent workflow 产出,主会话逐文件复核 + 亲自 build/test 把关。

## 交付(6 commits,19 XCTest 绿,`swift build` 0 error,`build-app.sh` 出 bundle)

| # | commit | 内容 |
|---|--------|------|
| 1 | `1e6f1e9` | 设置模型:`barWidth`/`deepSeekAPIKey`/`obsidianVaultPath`(持久化)+ `layoutEditing`(瞬态)+ 4 测试 |
| 2 | `b0b84af` | Phase 4:`PermissionsManager`(启动请求麦克风+屏录)、bar 拖动/宽度、bar 位置存 `ls.barX/Y` |
| 3 | `e9b7069` | Phase 5:`ObsidianExporter` / `DeepSeekClient` / `ExportCoordinator` / `SettingsView` |
| 4 | `7714802` | App 接线:菜单控件、`Settings` scene、导出按钮、`AppDelegate` 启动权限 |
| 5 | `1468b57` | Phase 4:mini 窗原生可缩放 + 尺寸持久化 `ls.miniW/miniH` |

## 关键实现决策

- **启动请求权限**用 `@NSApplicationDelegateAdaptor` + `applicationDidFinishLaunching`,**不用**菜单 `.task`(默认 `.menu` 样式的 MenuBarExtra 内容要等用户点开菜单才构建,达不到"开 app 即请求")。
- **bar 点击穿透是默认**,只有 `layoutEditing==true` 时才 `ignoresMouseEvents=false` + 可拖 + 黄色虚线边框提示;关掉恢复穿透。
- **bar 尺寸用菜单滑条**(确定性、可测),**mini 用原生边缘缩放**(`.resizable` borderless panel + `host.autoresizingMask` + `.frame(maxWidth/Height:.infinity)`)。
- **导出手动触发**(菜单按钮),尊重"只有主动导出才把转录发 DeepSeek 云"的隐私边界;无 key/失败都回退并仍写本地 .md。
- **API key 存 UserDefaults 明文**——自用取舍,未来沙盒化换 Keychain。

## Swift 6 并发

- 所有新 UI/AppKit 代码 `@MainActor`;新回调无 `@unchecked Sendable`/`nonisolated(unsafe)`。
- NSWindow move/resize 回调照抄既有 mini 的 `MainActor.assumeIsolated + [weak self]`。
- `DeepSeekClient` 纯值 struct + async,`Result` Sendable。

## 后续变更(2026-07-30,同一分支继续)

| commit | 内容 |
|--------|------|
| `359b499` | 复审修复:幽灵浮窗(hide 后改设置会复活)、导出同名覆盖、导出重入、YAML title 转义、设置窗置前 |
| `cf247ce` | 翻译三项:**边说边译**(中间态也翻,降延迟,菜单可关)、失败回退显原文(不再永久「翻译中…」)、仅原文模式跳翻译 |
| `0dfd750` | 全量复审修复:**孤儿 SCStream**(停止后屏录仍开)、半句译文被当定稿译文、旧 consume 写脏新会话、识别流静默冻结 |
| `61c3c17` | store:id→index O(1) 查找 + 保留上限 2000 行(长会话内存/延迟蠕变) |
| `5bfdfe8` | 字幕条大字号不再被裁(底对齐)+ 属性变化就地更新(消除重建闪烁) |
| `9f1e86c` → `7c52a9a` | 外观控件位置:先试字幕条旁齿轮浮窗 → 用户判定不好看,**改回菜单栏并换 `.menuBarExtraStyle(.window)`**(原生 NSMenu 渲染不了滑块,会退化成 Decrement/Increment) |
| `97cc9dd` | 应用图标:`scripts/make-icon.swift` 纯 AppKit 生成 `.icns`(bars/cjk/mixed 三风格,默认 cjk)接入 bundle |

**期间做了两轮多 agent 代码复审**(5 个 commit 逐一审 + 6 个子系统全量审),真 bug 都已修并有单测覆盖;被复审排除的疑点见各 commit message。

## ✅ 真机手测(2026-07-30,用户验收通过)

用户实机跑过并确认「功能都正常」,覆盖 Phase 3/4/5 全部交互:显示三态、字幕条⇄小窗、Pin、透明度/字号/宽度、布局编辑拖动、小窗缩放、启动权限、设置页、导出。

> 记录口径:此结论来自用户的实机反馈,不是自动化测试断言。单测(31)只覆盖 store/模型/格式转换等纯逻辑层。

## 已知取舍(非缺陷)

- **API key 明文存 UserDefaults** —— 自用取舍,上架/沙盒化再换 Keychain。
- **保留行数上限 2000** —— 极长会话会丢最早的回看历史(导出用当前保留的行)。
- **本地翻译逐句、无上下文、句界依赖 STT** —— Apple 本地 `TranslationSession` 的固有上限,要上下文得上云,与"实时链路不上云"的决策冲突,故不做。
- **拔外接屏时已显示的浮窗不会自动重定位**(无 `didChangeScreenParametersNotification` 监听);下次创建时 `clampToScreen` 会夹回屏内。
- **菜单栏图标仍是单色 SF Symbol**;`.icns` 只在 Finder/聚焦/简介可见(LSUIElement 无 Dock 图标)。

## 未动

音频 / 识别管线(`Audio/**` `Speech/**` `Pipeline/**` 的采集与识别部分)保持原状;本轮只在 `CaptionEngine` 编排层和 `TranslationService` 上按需改动(边说边译、串行化、错误上报)。
