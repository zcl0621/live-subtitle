import SwiftUI

/// 单行渲染,bar 与 mini 复用。读 displayMode/fontSize。
struct SubtitleLineRow: View {
    let line: SubtitleLine
    let displayMode: DisplayMode
    let fontSize: Double
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(line.speaker == .me ? "我" : "对方")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(line.speaker == .me ? Color.blue : Color.orange)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 3) {
                if displayMode.showsOriginal {
                    Text(line.original)
                        .font(.system(size: fontSize * 0.68))
                        .foregroundStyle(.white.opacity(line.isFinal ? 0.6 : 0.4))
                        .italic(!line.isFinal)
                }
                if displayMode.showsTranslated {
                    if let zh = line.translated {
                        Text(zh).font(.system(size: fontSize, weight: .medium)).foregroundStyle(.white)
                    } else if line.translationFailed {
                        if displayMode == .translatedOnly {
                            // 仅译文模式:译文不可用时回退显原文,避免整行空白
                            Text(line.original).font(.system(size: fontSize, weight: .medium))
                                .foregroundStyle(.white.opacity(0.85))
                        } else {
                            Text("(译文不可用)").font(.system(size: fontSize * 0.6))
                                .foregroundStyle(.white.opacity(0.35))
                        }
                    } else if line.isFinal {
                        Text("翻译中…").font(.system(size: fontSize * 0.64)).foregroundStyle(.white.opacity(0.3))
                    }
                }
            }
        }
    }
}

struct SubtitleBarView: View {
    var store: SubtitleStore
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)          // 把字幕气泡顶到 panel 底部,上方多余高度透明
            VStack(alignment: .leading, spacing: 12) {
                ForEach(store.lines.suffix(3)) { line in
                    SubtitleLineRow(line: line, displayMode: store.displayMode, fontSize: store.fontSize)
                }
            }
            .padding(18)
            .frame(width: store.barWidth, alignment: .leading)
            .background(.black.opacity(store.opacity), in: RoundedRectangle(cornerRadius: 18))
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(
                        store.layoutEditing ? Color.yellow.opacity(0.9) : Color.white.opacity(0.1),
                        style: store.layoutEditing
                            ? StrokeStyle(lineWidth: 2.5, dash: [8, 5])
                            : StrokeStyle(lineWidth: 1)
                    )
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
