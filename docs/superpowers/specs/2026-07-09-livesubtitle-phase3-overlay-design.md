# LiveSubtitle Phase 3 — Overlay 打磨 Design

**日期:** 2026-07-09
**状态:** brainstorming 定稿,待写实现 plan

## Goal

在双轨字幕(Phase 2 已交付)基础上,把 overlay 做成可用可调:显示三态切换、字幕条/小窗两形态、置顶 Pin、透明度/字号调节,设置跨启动记住。全部通过菜单栏 💬 下拉控制(对齐 Phase 1 的 Figma 交互原型 `c5JyauggBkkyIbDkRbgxQA`:F1 双语条 / F2 仅译文 / F3 仅原文 / F4 小窗 / F5 小窗+Pin / F6 菜单)。

## 承接现状

- 数据/枚举已就绪:`enum DisplayMode { originalOnly, both, translatedOnly }`、`enum OverlayMode { bar, mini }`;`SubtitleStore` 已有 `displayMode`、`overlayMode`。
- 现有 `SubtitleBarView`(底部条,最近 3 行)+ `OverlayController`(nonactivating NSPanel)。
- 控制面板:菜单栏驱动(用户已定),不做悬浮控件。

## 功能设计

### 1. 显示三态(菜单单选:原文 / 双语 / 译文)
`SubtitleBarView` 与新 `MiniWindowView` 都读 `store.displayMode`:
- `both`(默认):原文(灰)+ 译文(白)
- `translatedOnly`:只显示译文;无译文时显示"翻译中…"占位
- `originalOnly`:只显示原文,不显示译文/占位

### 2. 形态切换(菜单单选:字幕条 / 小窗)
读 `store.overlayMode`,`OverlayController` 据此切换承载面板:
- **字幕条 bar**(现状):底部居中、`lines.suffix(3)`、点击穿透(不挡操作)、不可交互。
- **小窗 mini**:小浮窗(默认约 380×480),显示**全部历史 + 竖向滚动**、新句自动滚到底、**可拖动换位置**(Phase 3 不可缩放,缩放留 Phase 4)。

### 3. Pin 置顶(菜单勾选,默认关)
把 overlay 面板层级提到**所有窗口之上**(比普通 `.floating` 更高,如 `.screenSaver`/`statusBar` 级别),压在其他 app 的浮窗之上且不被覆盖。关闭时回到 `.floating`。

### 4. 透明度(菜单滑条,40%–100%)
调整整个 overlay 背景不透明度;`SubtitleBarView`/`MiniWindowView` 的背景读 `store.opacity`。

### 5. 字号(菜单滑条/步进,译文 16–32pt)
译文字号读 `store.fontScale`(或 fontSize);原文按比例。

### 6. 记住设置(UserDefaults,跨启动)
持久化:`displayMode`、`overlayMode`、`opacity`、`fontSize`、`pinned`、小窗位置。启动读回、变更即写。

## 架构

- **设置状态**:在 `@MainActor @Observable SubtitleStore` 上补 `opacity: Double`、`fontSize: Double`、`pinned: Bool`(承接 Phase 1 已把 `displayMode`/`overlayMode` 放这儿的做法);各属性 `didSet` 写 UserDefaults,`init` 读回。小窗位置单独存。
- **OverlayController**:持有 bar 面板与 mini 面板;`overlayMode` 变化时切换显示哪个;`pinned` 变化时设 `panel.level`;透明度/字号由视图订阅 store 自动刷新。mini 面板 `isMovableByWindowBackground = true` 实现拖动 + 记住位置。
- **菜单(LiveSubtitleApp `MenuBarExtra`)**:`Picker`(显示三态)、`Picker`/分段(形态)、`Toggle`(Pin)、`Slider`(透明度)、`Slider`(字号),全部 `@Bindable` 绑 store。
- **视图**:`SubtitleBarView` 加 displayMode/opacity/fontSize 支持;新增 `MiniWindowView`(ScrollView + 历史 + 自动滚底)。

## 明确不做(留 Phase 4)

字幕条的拖拽/缩放、小窗缩放、延迟调优 spike、音频路由变化处理、外放漏音抑制。

## 完成定义(DoD)

- 菜单栏可切:显示三态、字幕条/小窗、Pin、透明度、字号,实时生效。
- 小窗显示滚动历史、新句自动滚底、可拖动。
- Pin 开启后压在其他窗口之上。
- 重启 app 后设置(含小窗位置)保持。
- 相关单测通过(显示模式过滤逻辑、设置持久化读写)。
