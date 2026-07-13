import SwiftUI
import AppKit

@main
struct LiveSubtitleApp: App {
    @State private var store = SubtitleStore()
    @State private var engine: CaptionEngine?
    @State private var overlay = OverlayController()
    @State private var running = false
    @State private var status = ""
    @State private var exportStatus = ""
    @State private var isExporting = false

    // 启动即请求权限(麦克风 + 屏幕录制)——用 AppDelegate 的 applicationDidFinishLaunching,
    // 而非菜单内容的 .task(后者要等用户点开菜单才触发)。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        MenuBarExtra("LiveSubtitle", systemImage: "captions.bubble") {
          Group {
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

            Toggle("布局编辑(拖动字幕条)", isOn: $s.layoutEditing)
            Text("字幕条宽度")
            Slider(value: $s.barWidth, in: 600...1400, step: 20)
            Divider()

            Button("整理并导出到 Obsidian") { exportToObsidian() }
                .disabled(isExporting)
            if !exportStatus.isEmpty { Text(exportStatus).font(.caption) }
            Button("设置…") {
                NSApp.activate(ignoringOtherApps: true)   // 菜单栏触发时确保设置窗口置前获焦
                openSettings()
            }
            Divider()

            Button("退出") { NSApplication.shared.terminate(nil) }
          }
        }

        Settings {
            SettingsView(store: store)
        }
    }

    @MainActor private func exportToObsidian() {
        guard !isExporting else { return }   // 防重入:进行中不再并发触发(避免重复上云 + 竞争写盘)
        isExporting = true
        exportStatus = "正在整理…"
        Task {
            let result = await ExportCoordinator.exportToObsidian(store: store)
            exportStatus = result
            isExporting = false
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

/// 启动即请求 麦克风 + 屏幕录制 授权(不等到点"开始字幕",也不等用户点开菜单)。
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        PermissionsManager.requestAllOnLaunch()
    }
}
