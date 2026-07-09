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

    /// 观察 overlayMode / pinned,变化即重配并重新武装观察。
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
        let p = (store.overlayMode == .bar) ? makeBarPanel(store) : makeMiniPanel(store)
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
        return p
    }

    private func removeMoveObserver() {
        if let o = moveObserver { NotificationCenter.default.removeObserver(o); moveObserver = nil }
    }
}
