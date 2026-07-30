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
        // .window 样式:下拉是真正的 SwiftUI 面板,滑块能正常渲染并拖动
        // (默认 .menu 走原生 NSMenu,Slider 会退化成 Decrement/Increment 子菜单)
        MenuBarExtra("LiveSubtitle", systemImage: "captions.bubble") {
            menuPanel
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store)
        }
    }

    @ViewBuilder private var menuPanel: some View {
        @Bindable var s = store
        VStack(alignment: .leading, spacing: 12) {
            Button(running ? "停止字幕" : "开始字幕") { toggle() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Picker("显示", selection: $s.displayMode) {
                Text("原文").tag(DisplayMode.originalOnly)
                Text("双语").tag(DisplayMode.both)
                Text("译文").tag(DisplayMode.translatedOnly)
            }.pickerStyle(.segmented)
            Picker("形态", selection: $s.overlayMode) {
                Text("字幕条").tag(OverlayMode.bar)
                Text("小窗").tag(OverlayMode.mini)
            }.pickerStyle(.segmented)

            Toggle("边说边译(中间态)", isOn: $s.translateVolatile)
            Toggle("置顶 Pin", isOn: $s.pinned)
            Toggle("布局编辑(拖动字幕条)", isOn: $s.layoutEditing)

            Divider()

            slider("透明度", value: $s.opacity, in: 0.4...1.0, display: "\(Int(store.opacity * 100))%")
            slider("字号", value: $s.fontSize, in: 16...32, step: 1, display: "\(Int(store.fontSize))")
            if store.overlayMode == .bar {
                slider("字幕条宽度", value: $s.barWidth, in: 600...1400, step: 20, display: "\(Int(store.barWidth))")
            }

            Divider()

            Button("整理并导出到 Obsidian") { exportToObsidian() }
                .disabled(isExporting)
                .frame(maxWidth: .infinity)
            if !exportStatus.isEmpty {
                Text(exportStatus).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("设置…") {
                    NSApp.activate(ignoringOtherApps: true)   // 菜单栏触发时确保设置窗口置前获焦
                    openSettings()
                }
                Spacer()
                Button("退出") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    /// 带右侧数值的紧凑滑块行(.window 样式下 Slider 正常可用)。
    @ViewBuilder private func slider(_ title: String, value: Binding<Double>,
                                     in range: ClosedRange<Double>, step: Double? = nil,
                                     display: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(display).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            if let step {
                Slider(value: value, in: range, step: step)
            } else {
                Slider(value: value, in: range)
            }
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
