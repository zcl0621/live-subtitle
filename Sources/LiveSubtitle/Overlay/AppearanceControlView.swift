import SwiftUI

/// 外观控制浮层:齿轮收起 / 展开为 透明度·字号·(字幕条)宽度 滑块。
/// 独立可点击小窗——字幕条要保持点击穿透,故这些控件必须自成一窗(见 OverlayController.makeGearPanel)。
struct AppearanceControlView: View {
    @Bindable var store: SubtitleStore

    var body: some View {
        Group {
            if store.appearanceExpanded { expanded } else { collapsed }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var collapsed: some View {
        Button { store.appearanceExpanded = true } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black.opacity(0.7), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("外观设置")
    }

    private var expanded: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "gearshape.fill").font(.system(size: 12)).foregroundStyle(.white.opacity(0.8))
                Text("外观").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                Spacer()
                Button { store.appearanceExpanded = false } label: {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                }.buttonStyle(.plain).help("收起")
            }
            row("透明度") { Slider(value: $store.opacity, in: 0.4...1.0) }
            row("字号 \(Int(store.fontSize))") { Slider(value: $store.fontSize, in: 16...32, step: 1) }
            if store.overlayMode == .bar {
                row("字幕条宽度 \(Int(store.barWidth))") { Slider(value: $store.barWidth, in: 600...1400, step: 20) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
    }

    private func row<Content: View>(_ title: String, @ViewBuilder _ control: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            control()
        }
    }
}
