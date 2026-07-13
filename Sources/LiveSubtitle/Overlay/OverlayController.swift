import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    private var panel: NSPanel?
    private var store: SubtitleStore?
    private var moveObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
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

    /// 观察 overlayMode / pinned / barWidth / layoutEditing,变化即重配并重新武装观察。
    private func observe() {
        guard let store else { return }
        withObservationTracking {
            _ = store.overlayMode
            _ = store.pinned
            _ = store.barWidth
            _ = store.layoutEditing
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
        let p = (store.overlayMode == .bar) ? makeBarPanel(store) : makeMiniPanel(store)
        p.level = store.pinned ? .screenSaver : .floating
        p.orderFrontRegardless()
        panel = p
    }

    private func makeBarPanel(_ store: SubtitleStore) -> NSPanel {
        let width = store.barWidth
        let host = NSHostingView(rootView: SubtitleBarView(store: store))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 200)
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
        if let x = defaults.object(forKey: "ls.barX") as? Double,
           let y = defaults.object(forKey: "ls.barY") as? Double {
            p.setFrameOrigin(NSPoint(x: x, y: y))
        } else if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - width / 2, y: f.minY + 60))
        }
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
        let p = NSPanel(contentRect: host.frame, styleMask: [.nonactivatingPanel, .borderless, .resizable],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.isMovableByWindowBackground = true          // 小窗可拖(边缘仍可缩放)
        p.minSize = NSSize(width: 260, height: 180)    // 缩放下限
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
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
}
