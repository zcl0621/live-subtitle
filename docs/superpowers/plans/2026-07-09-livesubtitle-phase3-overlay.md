# LiveSubtitle Phase 3 — Overlay 打磨 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 菜单栏驱动的 overlay 打磨:显示三态(原文/双语/译文)、字幕条⇄小窗(小窗=滚动历史+可拖)、Pin 置顶(压所有窗口)、透明度、字号,全部设置跨启动记住。

**Architecture:** 设置状态放 `@MainActor @Observable SubtitleStore`(承接 Phase 1 已把 displayMode/overlayMode 放这儿),新增 opacity/fontSize/pinned + UserDefaults 持久化。`SubtitleBarView` 与新 `MiniWindowView` 订阅 store 自动刷新显示三态/透明度/字号。`OverlayController` 观察 overlayMode/pinned 切换 bar/mini 面板与窗口层级,小窗 `isMovableByWindowBackground` 拖动并记住位置。菜单(`MenuBarExtra`)用 `@Bindable` 绑 store。

**Tech Stack:** Swift 6 · macOS 26 SDK · SwiftPM · SwiftUI(Picker/Slider/Toggle/ScrollViewReader)· AppKit(NSPanel/NSWindow.Level)· Observation · UserDefaults · XCTest。

> **命令(承接):** `swift build` / `swift test --filter X` / GUI:`bash scripts/build-app.sh && open build/LiveSubtitle.app`。

---

## File Structure

| 文件 | 责任 | 动作 |
|---|---|---|
| `Sources/LiveSubtitle/Models/SubtitleModels.swift` | DisplayMode/OverlayMode 加 String raw + CaseIterable;DisplayMode 显示助手 | Modify |
| `Sources/LiveSubtitle/Models/SubtitleStore.swift` | 加 opacity/fontSize/pinned + 注入 UserDefaults 持久化 | Modify |
| `Sources/LiveSubtitle/Overlay/SubtitleBarView.swift` | 读 displayMode/opacity/fontSize | Modify |
| `Sources/LiveSubtitle/Overlay/MiniWindowView.swift` | 滚动历史小窗视图 | Create |
| `Sources/LiveSubtitle/Overlay/OverlayController.swift` | bar/mini 面板切换、pin 层级、小窗拖动+记忆位置 | Modify |
| `Sources/LiveSubtitle/LiveSubtitleApp.swift` | 菜单加 显示/形态/Pin/透明度/字号 控件 | Modify |
| `Tests/LiveSubtitleTests/SubtitleSettingsTests.swift` | 持久化往返 + DisplayMode 助手 | Create |

---

## Task 1: 设置模型 + 持久化

**Files:**
- Modify: `Sources/LiveSubtitle/Models/SubtitleModels.swift`
- Modify: `Sources/LiveSubtitle/Models/SubtitleStore.swift`
- Create: `Tests/LiveSubtitleTests/SubtitleSettingsTests.swift`

- [ ] **Step 1: 枚举加 String raw + CaseIterable + 显示助手**

`SubtitleModels.swift` 里改这两个枚举并加扩展:

```swift
enum DisplayMode: String, Sendable, CaseIterable { case originalOnly, both, translatedOnly }
enum OverlayMode: String, Sendable, CaseIterable { case bar, mini }

extension DisplayMode {
    var showsOriginal: Bool { self != .translatedOnly }
    var showsTranslated: Bool { self != .originalOnly }
}
```

- [ ] **Step 2: 写失败测试**

`Tests/LiveSubtitleTests/SubtitleSettingsTests.swift`:

```swift
import XCTest
@testable import LiveSubtitle

@MainActor
final class SubtitleSettingsTests: XCTestCase {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "test.ls.\(UUID().uuidString)")!
    }

    func testDefaultsWhenEmpty() {
        let s = SubtitleStore(defaults: freshSuite())
        XCTAssertEqual(s.displayMode, .both)
        XCTAssertEqual(s.overlayMode, .bar)
        XCTAssertEqual(s.opacity, 0.82, accuracy: 0.0001)
        XCTAssertEqual(s.fontSize, 22, accuracy: 0.0001)
        XCTAssertFalse(s.pinned)
    }

    func testSettingsPersistAcrossInstances() {
        let suite = freshSuite()
        let s1 = SubtitleStore(defaults: suite)
        s1.displayMode = .translatedOnly
        s1.overlayMode = .mini
        s1.opacity = 0.5
        s1.fontSize = 28
        s1.pinned = true
        let s2 = SubtitleStore(defaults: suite)   // 新实例从同一 suite 读回
        XCTAssertEqual(s2.displayMode, .translatedOnly)
        XCTAssertEqual(s2.overlayMode, .mini)
        XCTAssertEqual(s2.opacity, 0.5, accuracy: 0.0001)
        XCTAssertEqual(s2.fontSize, 28, accuracy: 0.0001)
        XCTAssertTrue(s2.pinned)
    }

    func testDisplayModeHelpers() {
        XCTAssertTrue(DisplayMode.both.showsOriginal)
        XCTAssertTrue(DisplayMode.both.showsTranslated)
        XCTAssertFalse(DisplayMode.translatedOnly.showsOriginal)
        XCTAssertTrue(DisplayMode.translatedOnly.showsTranslated)
        XCTAssertTrue(DisplayMode.originalOnly.showsOriginal)
        XCTAssertFalse(DisplayMode.originalOnly.showsTranslated)
    }
}
```

- [ ] **Step 3: 跑测试确认失败**

Run: `swift test --filter SubtitleSettingsTests`
Expected: FAIL(`SubtitleStore(defaults:)`、`opacity`/`fontSize`/`pinned` 未定义)。

- [ ] **Step 4: 实现 store 设置 + 持久化**

`SubtitleStore.swift`:把 `displayMode`/`overlayMode` 的内联默认去掉,加新设置属性(各带 didSet 落盘),加注入式 init 读回。keys 用 `"ls.*"`。

```swift
@MainActor
@Observable
final class SubtitleStore {
    private let defaults: UserDefaults
    private(set) var lines: [SubtitleLine] = []

    var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: "ls.displayMode") } }
    var overlayMode: OverlayMode { didSet { defaults.set(overlayMode.rawValue, forKey: "ls.overlayMode") } }
    var opacity: Double { didSet { defaults.set(opacity, forKey: "ls.opacity") } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "ls.fontSize") } }
    var pinned: Bool { didSet { defaults.set(pinned, forKey: "ls.pinned") } }

    private var volatileIndex: [Speaker: Int] = [:]
    private var pendingVolatile: [Speaker: String] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "ls.displayMode") ?? "") ?? .both
        overlayMode = OverlayMode(rawValue: defaults.string(forKey: "ls.overlayMode") ?? "") ?? .bar
        opacity = defaults.object(forKey: "ls.opacity") as? Double ?? 0.82
        fontSize = defaults.object(forKey: "ls.fontSize") as? Double ?? 22
        pinned = defaults.bool(forKey: "ls.pinned")
    }

    // …stageVolatile / flushVolatile / upsertVolatile / commitFinal / attachTranslation 原样保留…
}
```

> 注:`@Observable` 支持 stored 属性的 `didSet`。`didSet` 在 init 内首次赋值时**不触发**(Swift 语义),故 init 读回不会反向写。若实测某属性 didSet 未触发,改用显式 `persist()` 并在菜单绑定处调用,并报告。

- [ ] **Step 5: 跑测试确认通过**

Run: `swift test --filter SubtitleSettingsTests` 然后 `swift test`
Expected: 新 3 条 + 既有全绿(既有 SubtitleStoreTests 用 `SubtitleStore()`,默认 `defaults: .standard`,不受影响)。

- [ ] **Step 6: Commit**

```bash
git add Sources/LiveSubtitle/Models/SubtitleModels.swift Sources/LiveSubtitle/Models/SubtitleStore.swift Tests/LiveSubtitleTests/SubtitleSettingsTests.swift
git commit -m "feat: overlay settings (opacity/fontSize/pinned) + UserDefaults persistence"
```

---

## Task 2: SubtitleBarView 支持显示三态 / 透明度 / 字号

**Files:**
- Modify: `Sources/LiveSubtitle/Overlay/SubtitleBarView.swift`

- [ ] **Step 1: 改视图读 store 设置**

`SubtitleBarView.swift` 全文替换(逐行渲染抽成子视图 `SubtitleLineRow` 便于 mini 复用):

```swift
import SwiftUI

/// 单行渲染,bar 与 mini 复用。读 displayMode/fontSize。
struct SubtitleLineRow: View {
    let line: SubtitleLine
    let displayMode: DisplayMode
    let fontSize: Double
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(line.speaker == .me ? "我" : "对方")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(line.speaker == .me ? Color.blue : Color.orange)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                if displayMode.showsOriginal {
                    Text(line.original)
                        .font(.system(size: fontSize * 0.68))
                        .foregroundStyle(.white.opacity(line.isFinal ? 0.6 : 0.4))
                        .italic(!line.isFinal)
                }
                if displayMode.showsTranslated {
                    if let zh = line.translated {
                        Text(zh).font(.system(size: fontSize, weight: .medium)).foregroundStyle(.white)
                    } else if line.isFinal {
                        Text("翻译中…").font(.system(size: fontSize * 0.64)).foregroundStyle(.white.opacity(0.3))
                    }
                }
            }
        }
    }
}

struct SubtitleBarView: View {
    var store: SubtitleStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.lines.suffix(3)) { line in
                SubtitleLineRow(line: line, displayMode: store.displayMode, fontSize: store.fontSize)
            }
        }
        .padding(18)
        .frame(width: 900, alignment: .leading)
        .background(.black.opacity(store.opacity), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.1)))
    }
}
```

- [ ] **Step 2: 编译**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/LiveSubtitle/Overlay/SubtitleBarView.swift
git commit -m "feat: SubtitleBarView respects displayMode/opacity/fontSize; extract SubtitleLineRow"
```

---

## Task 3: MiniWindowView(滚动历史小窗)

**Files:**
- Create: `Sources/LiveSubtitle/Overlay/MiniWindowView.swift`

- [ ] **Step 1: 写 MiniWindowView**

`Sources/LiveSubtitle/Overlay/MiniWindowView.swift`:

```swift
import SwiftUI

/// 小窗:全部历史 + 竖向滚动,新句自动滚到底。复用 SubtitleLineRow。
struct MiniWindowView: View {
    var store: SubtitleStore
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(store.lines) { line in
                        SubtitleLineRow(line: line, displayMode: store.displayMode, fontSize: store.fontSize)
                            .id(line.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(14)
            }
            .onChange(of: store.lines.count) {
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .frame(width: 380, height: 480)
        .background(.black.opacity(store.opacity), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
    }
}
```

- [ ] **Step 2: 编译**

Run: `swift build`
Expected: `Build complete!`

- [ ] **Step 3: Commit**

```bash
git add Sources/LiveSubtitle/Overlay/MiniWindowView.swift
git commit -m "feat: MiniWindowView scrollable history with auto-scroll-to-bottom"
```

---

## Task 4: OverlayController — bar/mini 切换 + Pin 层级 + 小窗拖动记忆

**Files:**
- Modify: `Sources/LiveSubtitle/Overlay/OverlayController.swift`

- [ ] **Step 1: 重写 OverlayController**

`OverlayController.swift` 全文替换。要点:`show(store:)` 起观察;`applyMode()` 按 `overlayMode` 建 bar 或 mini 面板(bar 底部居中、宽、点击穿透;mini 小、可拖、恢复保存位置);`applyPinned()` 设面板 level;`withObservationTracking` 监听 `overlayMode`+`pinned` 变化并重配;小窗移动经 `NSWindow.didMoveNotification` 存位置。

```swift
import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    private var panel: NSPanel?
    private var store: SubtitleStore?
    private var moveObserver: NSObjectProtocol?
    private let defaults = UserDefaults.standard

    func show(store: SubtitleStore) {
        self.store = store
        applyMode()
        observe()
    }

    func hide() {
        removeMoveObserver()
        panel?.orderOut(nil)
        panel = nil
    }

    // 观察 overlayMode / pinned,变化即重配并重新武装观察
    private func observe() {
        guard let store else { return }
        withObservationTracking {
            _ = store.overlayMode
            _ = store.pinned
        } onChange: {
            Task { @MainActor in
                self.applyMode()
                self.observe()
            }
        }
    }

    private func applyMode() {
        guard let store else { return }
        removeMoveObserver()
        panel?.orderOut(nil)
        let p: NSPanel = (store.overlayMode == .bar) ? makeBarPanel(store) : makeMiniPanel(store)
        p.level = store.pinned ? .screenSaver : .floating
        p.orderFrontRegardless()
        panel = p
    }

    private func makeBarPanel(_ store: SubtitleStore) -> NSPanel {
        let host = NSHostingView(rootView: SubtitleBarView(store: store))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 200)
        let p = NSPanel(contentRect: host.frame, styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true                 // 字幕条点击穿透
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - 450, y: f.minY + 60))
        }
        return p
    }

    private func makeMiniPanel(_ store: SubtitleStore) -> NSPanel {
        let host = NSHostingView(rootView: MiniWindowView(store: store))
        host.frame = NSRect(x: 0, y: 0, width: 380, height: 480)
        let p = NSPanel(contentRect: host.frame, styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true         // 小窗可拖
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        // 恢复保存位置,否则右下角
        if let x = defaults.object(forKey: "ls.miniX") as? Double,
           let y = defaults.object(forKey: "ls.miniY") as? Double {
            p.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.maxX - 400, y: f.minY + 80))
        }
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.defaults.set(Double(p.frame.origin.x), forKey: "ls.miniX")
                self?.defaults.set(Double(p.frame.origin.y), forKey: "ls.miniY")
            }
        }
        return p
    }

    private func removeMoveObserver() {
        if let o = moveObserver { NotificationCenter.default.removeObserver(o); moveObserver = nil }
    }
}
```

- [ ] **Step 2: 编译**

Run: `swift build`
Expected: `Build complete!`(若 `withObservationTracking`/`MainActor.assumeIsolated` 报 Swift 6 隔离错,按提示把闭包内访问收敛到 MainActor;不要弱化 store 隔离。如卡住报告。)

- [ ] **Step 3: Commit**

```bash
git add Sources/LiveSubtitle/Overlay/OverlayController.swift
git commit -m "feat: OverlayController bar/mini switch, Pin window level, draggable mini with saved position"
```

---

## Task 5: 菜单栏控件

**Files:**
- Modify: `Sources/LiveSubtitle/LiveSubtitleApp.swift`

- [ ] **Step 1: 菜单加控件(绑 store)**

`LiveSubtitleApp.swift` 的 `MenuBarExtra` 内容替换为(用 `@Bindable`):

```swift
import SwiftUI
import AppKit

@main
struct LiveSubtitleApp: App {
    @State private var store = SubtitleStore()
    @State private var engine: CaptionEngine?
    @State private var overlay = OverlayController()
    @State private var running = false
    @State private var status = ""

    var body: some Scene {
        MenuBarExtra("LiveSubtitle", systemImage: "captions.bubble") {
            @Bindable var s = store
            Button(running ? "停止字幕" : "开始字幕") { toggle() }
            if !status.isEmpty { Text(status).font(.caption) }
            Divider()

            Picker("显示", selection: $s.displayMode) {
                Text("原文").tag(DisplayMode.originalOnly)
                Text("双语").tag(DisplayMode.both)
                Text("译文").tag(DisplayMode.translatedOnly)
            }
            Picker("形态", selection: $s.overlayMode) {
                Text("字幕条").tag(OverlayMode.bar)
                Text("小窗").tag(OverlayMode.mini)
            }
            Toggle("置顶 Pin", isOn: $s.pinned)
            Divider()

            Text("透明度")
            Slider(value: $s.opacity, in: 0.4...1.0)
            Text("字号")
            Slider(value: $s.fontSize, in: 16...32, step: 1)
            Divider()

            Button("退出") { NSApplication.shared.terminate(nil) }
        }
    }

    @MainActor private func toggle() {
        if running {
            engine?.stop(); engine = nil; overlay.hide(); running = false; status = ""
        } else {
            let e = CaptionEngine(store: store)
            engine = e
            overlay.show(store: store)
            e.start(onError: { status = $0 })
            running = true
        }
    }
}
```

- [ ] **Step 2: 编译 + 打包**

Run: `swift build && bash scripts/build-app.sh`
Expected: `Build complete!` + `built: build/LiveSubtitle.app`

- [ ] **Step 3: 全量测试**

Run: `swift test`
Expected: 全绿(设置测试 + 既有)。

- [ ] **Step 4: Commit**

```bash
git add Sources/LiveSubtitle/LiveSubtitleApp.swift
git commit -m "feat: menu controls for display mode / overlay form / Pin / opacity / font size"
```

---

## Task 6: 端到端手测(用户执行)

- [ ] **Step 1:** `open build/LiveSubtitle.app` → 开始字幕。
- [ ] **Step 2:** 菜单切 显示三态(原文/双语/译文)→ 字幕条实时变。
- [ ] **Step 3:** 菜单切 形态=小窗 → 出现小窗、显示滚动历史、新句自动滚底、可拖动;切回字幕条正常。
- [ ] **Step 4:** 勾 Pin → 打开别的浮动窗口验证 overlay 压在其上;取消恢复。
- [ ] **Step 5:** 拉 透明度 / 字号 滑条 → overlay 实时变。
- [ ] **Step 6:** 退出 app,重开 → 显示模式/形态/透明度/字号/Pin/小窗位置 都保持。
- [ ] **Step 7:** 结果写 `probes/RESULTS.md` "Phase 3 端到端" 小节。

---

## 完成定义(DoD)

- 菜单可切:显示三态、字幕条/小窗、Pin、透明度、字号,实时生效。
- 小窗滚动历史 + 自动滚底 + 可拖。
- Pin 压其他窗口之上。
- 重启后设置(含小窗位置)保持。
- `swift test` 全绿。

## 后续(见 backlog.md)

Phase 4(字幕条拖拽/缩放 + 开 app 即请求权限)、Phase 5(Obsidian 导出 + DeepSeek 总结 + 设置页)。
