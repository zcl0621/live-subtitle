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

## ⏳ 未验证(需真机手测,不能靠单测覆盖)

1. bar 布局编辑拖动 + 宽度滑条实时变化;bar 位置重启后恢复。
2. mini 边缘缩放手感(borderless panel 边缘抓取区较窄,尤其需肉眼确认)+ 尺寸重启恢复。
3. 启动时麦克风 + 屏幕录制权限框弹出时机。
4. 设置页打开、`NSOpenPanel` 选 vault、填真 DeepSeek key → 真实调用 + 写出 .md 到 vault。

## 未动

音频 / 识别 / 翻译 / 管线(`Audio/**` `Speech/**` `Translation/**` `Pipeline/**`)一行没碰。
