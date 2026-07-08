import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    private var panel: NSPanel?

    func show(store: SubtitleStore) {
        let host = NSHostingView(rootView: SubtitleBarView(store: store))
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 200)
        let p = NSPanel(contentRect: host.frame,
                        styleMask: [.nonactivatingPanel, .borderless],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.becomesKeyOnlyIfNeeded = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = host
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - 450, y: f.minY + 60))
        }
        p.orderFrontRegardless()
        panel = p
    }

    func hide() { panel?.orderOut(nil); panel = nil }
}
