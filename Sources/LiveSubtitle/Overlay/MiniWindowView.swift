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
        .frame(minWidth: 260, maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
        .background(.black.opacity(store.opacity), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
    }
}
