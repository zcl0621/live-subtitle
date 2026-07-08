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
            Button(running ? "停止字幕" : "开始字幕") { toggle() }
            if !status.isEmpty { Text(status).font(.caption) }
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
