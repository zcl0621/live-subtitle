import AppKit
import SwiftUI

/// borderless 的 NSPanel 默认 `canBecomeKey == false`,里头的 TextField 收不到键盘
/// —— 小窗要支持点标签改名,必须能成 key。仍带 `.nonactivatingPanel`:
/// 点它只让这个浮窗取得键盘焦点,不把整个 app 激活到前台(不打断正在开的会)。
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class OverlayController {
    private var panel: NSPanel?
    private var store: SubtitleStore?
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private let defaults = UserDefaults.standard
    /// overlay 是否处于显示态。停止后为 false,阻止观察回调复活幽灵浮窗。
    private var active = false
    /// 观察代次:show/hide 时自增,使 hide 前武装的旧 withObservationTracking 回调失效(无法 cancel,只能靠代次作废)。
    private var generation = 0
    /// 当前 panel 的形态;用于判断观察变化是否需要整块重建(仅形态变才重建)。
    private var currentMode: OverlayMode?

    func show(store: SubtitleStore) {
        self.store = store
        active = true
        generation &+= 1
        applyMode()
        observe()
    }

    func hide() {
        active = false
        generation &+= 1        // 作废任何已武装的观察回调
        removeMoveObserver()
        panel?.orderOut(nil)
        panel = nil
        currentMode = nil
    }

    /// 观察 overlayMode / pinned / barWidth / layoutEditing,变化即重配并重新武装观察。
    /// active==false(已停止)或代次过期时,回调直接 no-op,不再重建浮窗、不再重新武装。
    private func observe() {
        guard active, let store else { return }
        let gen = generation
        withObservationTracking {
            _ = store.overlayMode
            _ = store.pinned
            _ = store.barWidth
            _ = store.layoutEditing
        } onChange: {
            Task { @MainActor in
                guard self.active, gen == self.generation else { return }
                self.reconfigure()
                self.observe()
            }
        }
    }

    /// 观察回调:仅形态(bar⇄mini)变化才整块重建;pinned/barWidth/layoutEditing 变化就地改属性,
    /// 避免每次调 Pin/拖宽度/切编辑态都重建 NSPanel(闪烁 + 丢滚动位置)。
    private func reconfigure() {
        guard active, let store else { return }
        if currentMode != store.overlayMode || panel == nil {
            applyMode()
        } else {
            updateInPlace(store)
        }
    }

    private func updateInPlace(_ store: SubtitleStore) {
        guard let p = panel else { return }
        p.level = store.pinned ? .screenSaver : .floating
        if store.overlayMode == .bar {
            p.ignoresMouseEvents = !store.layoutEditing
            p.isMovableByWindowBackground = store.layoutEditing
            if abs(p.frame.size.width - store.barWidth) > 0.5 {
                var f = p.frame
                f.size.width = store.barWidth          // 就地改宽:内容随 autoresize + SwiftUI 重排,不重建
                p.setFrame(f, display: true)
                clampToScreen(p)                       // 加宽可能顶出右边界
            }
        }
        // mini:layoutEditing/barWidth 与它无关,无需任何重建(消除小窗模式下切编辑态的白重建)
    }

    private func applyMode() {
        guard active, let store else { return }
        removeMoveObserver()
        panel?.orderOut(nil)
        let p = (store.overlayMode == .bar) ? makeBarPanel(store) : makeMiniPanel(store)
        p.level = store.pinned ? .screenSaver : .floating
        p.orderFrontRegardless()
        panel = p
        currentMode = store.overlayMode
    }

    private func makeBarPanel(_ store: SubtitleStore) -> NSPanel {
        let width = store.barWidth
        // 高度取足够容纳最大字号(32)+ 双语 + 3 行的量;内容在 SubtitleBarView 内底对齐,
        // 多出的空间透明不可见,字幕始终贴底不被裁。
        let height: CGFloat = 300
        let host = NSHostingView(rootView: SubtitleBarView(store: store))
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.autoresizingMask = [.width, .height]     // 就地改宽时内容跟随
        let p = NSPanel(contentRect: host.frame, styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        // 布局编辑态:字幕条可交互 + 可拖;否则点击穿透。
        p.ignoresMouseEvents = !store.layoutEditing
        p.isMovableByWindowBackground = store.layoutEditing
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        let barDefault: NSPoint = {
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                return NSPoint(x: f.midX - width / 2, y: f.minY + 60)
            }
            return NSPoint(x: 100, y: 100)
        }()
        if let x = defaults.object(forKey: "ls.barX") as? Double,
           let y = defaults.object(forKey: "ls.barY") as? Double {
            p.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            p.setFrameOrigin(barDefault)
        }
        clampToScreen(p)
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let origin = self.panel?.frame.origin else { return }
                self.defaults.set(Double(origin.x), forKey: "ls.barX")
                self.defaults.set(Double(origin.y), forKey: "ls.barY")
            }
        }
        return p
    }

    private func makeMiniPanel(_ store: SubtitleStore) -> NSPanel {
        let w = defaults.object(forKey: "ls.miniW") as? Double ?? 380
        let h = defaults.object(forKey: "ls.miniH") as? Double ?? 480
        let host = NSHostingView(rootView: MiniWindowView(store: store))
        host.frame = NSRect(x: 0, y: 0, width: w, height: h)
        host.autoresizingMask = [.width, .height]     // 内容随 panel 缩放
        let p = KeyablePanel(contentRect: host.frame, styleMask: [.nonactivatingPanel, .borderless, .resizable],
                             backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true          // 小窗可拖(边缘仍可缩放)
        p.minSize = NSSize(width: 260, height: 180)    // 缩放下限
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        let miniDefault: NSPoint = {
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                return NSPoint(x: f.maxX - 400, y: f.minY + 80)
            }
            return NSPoint(x: 100, y: 100)
        }()
        if let x = defaults.object(forKey: "ls.miniX") as? Double,
           let y = defaults.object(forKey: "ls.miniY") as? Double {
            p.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            p.setFrameOrigin(miniDefault)
        }
        clampToScreen(p)
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let origin = self.panel?.frame.origin else { return }
                self.defaults.set(Double(origin.x), forKey: "ls.miniX")
                self.defaults.set(Double(origin.y), forKey: "ls.miniY")
            }
        }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification, object: p, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let size = self.panel?.frame.size else { return }
                self.defaults.set(Double(size.width), forKey: "ls.miniW")
                self.defaults.set(Double(size.height), forKey: "ls.miniH")
            }
        }
        return p
    }

    private func removeMoveObserver() {
        if let o = moveObserver { NotificationCenter.default.removeObserver(o); moveObserver = nil }
        if let o = resizeObserver { NotificationCenter.default.removeObserver(o); resizeObserver = nil }
    }

    /// 把浮窗【完整】夹进某个屏幕的可见区——只判"有交集"是不够的(一角在屏内、其余溢出也会通过)。
    /// 覆盖溢出来源:恢复的旧坐标(拔显示器/改分辨率)、字幕条加宽、小窗尺寸恢复。
    private func clampToScreen(_ p: NSPanel) {
        let frame = p.frame
        // 取与窗口重叠最多的屏;完全在屏外时退到主屏
        let screen = NSScreen.screens.max {
            overlapArea($0.visibleFrame, frame) < overlapArea($1.visibleFrame, frame)
        } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        var origin = frame.origin
        origin.x = frame.width  <= vf.width  ? min(max(origin.x, vf.minX), vf.maxX - frame.width)  : vf.minX
        origin.y = frame.height <= vf.height ? min(max(origin.y, vf.minY), vf.maxY - frame.height) : vf.minY
        if origin != frame.origin { p.setFrameOrigin(origin) }
    }

    private func overlapArea(_ a: NSRect, _ b: NSRect) -> CGFloat {
        let r = a.intersection(b)
        return r.isNull ? 0 : r.width * r.height
    }
}
