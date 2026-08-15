import SwiftUI
import AppKit

@main
struct LiveSubtitleApp: App {
    @State private var store = SubtitleStore()
    @State private var engine: CaptionEngine?
    @State private var overlay = OverlayController()
    @State private var status = ""
    @State private var exportStatus = ""
    @State private var isExporting = false

    @Environment(\.openSettings) private var openSettings

    var body: some Scene {
        // 普通窗口 app(不再是菜单栏 app):控制面板是一个正常窗口,Dock 里有图标。
        // 字幕本身仍是独立浮窗(OverlayController 的 bar/mini),与本窗口无关。
        WindowGroup("LiveSubtitle") {
            controlPanel
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView(store: store)
        }
    }

    @ViewBuilder private var controlPanel: some View {
        @Bindable var s = store
        VStack(alignment: .leading, spacing: 12) {
            Button(store.isRunning ? "停止字幕" : "开始字幕") { toggle() }
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
            }
            .pickerStyle(.segmented)
            // 中文会议不产译文,三个选项都只会显示原文 —— 死控件,置灰并说明原因。
            .disabled(!displayModeSelectable)
            if !displayModeSelectable {
                Text("中文会议无译文,显示模式无从选起。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
            Button("设置…") { openSettings() }   // 退出走 app 菜单 / ⌘Q
        }
        .padding(16)
        .frame(width: 300)
    }

    /// 显示模式这组选项此刻有没有意义。**运行中看本场事实,没跑时看下一场设置** ——
    /// 两个语种字段各管一段时间:`sessionLanguage` 只在 `beginSession` 写,只跑时才是真相;
    /// 停着的时候它还停在上一场(或启动时的默认值)上,拿它门控就会出这个岔子:
    /// 上次开的是中文会议 → 重启后 Picker 灰着 → 用户去设置页改成 English → Picker 依然灰,
    /// 非得先开一次字幕才解锁,而这时候他早就想先把「双语」选好了。
    private var displayModeSelectable: Bool {
        store.isRunning ? store.sessionLanguage.needsTranslation
                        : store.meetingLanguage.needsTranslation
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
        if store.isRunning {
            engine?.stop(); engine = nil; overlay.hide(); store.isRunning = false; status = ""
        } else {
            // 权限在此刻(真正要用时)请求,不在启动时。
            // 启动阶段同时拉起麦克风 + 屏幕录制两个 TCC 流程会导致 MenuBarExtra 的状态栏项建不出来
            // (实测:单独请求任一项都正常,两项同时请求则菜单栏无图标,延后请求也无效)。
            PermissionsManager.requestAll()
            let e = CaptionEngine(store: store)
            engine = e
            overlay.show(store: store)
            e.start(onError: { status = $0 })
            store.isRunning = true
        }
    }
}

