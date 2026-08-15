import SwiftUI

/// 单行渲染,bar 与 mini 复用。读 displayMode/fontSize。
/// 说话人名由调用方从 store 取(改名映射在 store 上),配色由 SpeakerID 自己给。
struct SubtitleLineRow: View {
    let line: SubtitleLine
    let displayMode: DisplayMode
    let fontSize: Double
    let speakerName: String
    /// 非 nil 则说话人标签可点(小窗改名);字幕条是点击穿透的浮窗,传 nil。
    var onTapSpeaker: ((SpeakerID) -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            speakerLabel
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

    /// 说话人标签。归属是异步回填的,标签会从轨别名跳成真身份 ——
    /// 加一段短过渡,让它看起来是「判出来了」,而不是屏幕在抽搐。
    ///
    /// 始终是同一个 Button、靠 `disabled` 控制可点性,**不能**写成
    /// `if let onTapSpeaker, isRenamable { Button } else { chip }`:
    /// 那个 if 的分支切换恰好发生在 unresolved→真身份 的同一帧,
    /// `_ConditionalContent` 换分支会销毁重建视图、identity 断掉,
    /// implicit animation 没有前后值可插值,动画等于没写。
    @ViewBuilder private var speakerLabel: some View {
        Button { onTapSpeaker?(line.speaker) } label: {
            Text(speakerName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(line.speaker.color)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .animation(.easeInOut(duration: 0.15), value: line.speaker)
                .animation(.easeInOut(duration: 0.15), value: speakerName)
        }
        .buttonStyle(.plain)
        .disabled(!canRename)
        .help(canRename ? "点击改名" : "")   // 点不动的时候别提示能点
    }

    private var canRename: Bool {
        onTapSpeaker != nil && line.speaker.isRenamable
    }
}

struct SubtitleBarView: View {
    var store: SubtitleStore
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)          // 把字幕气泡顶到 panel 底部,上方多余高度透明
            VStack(alignment: .leading, spacing: 12) {
                ForEach(store.lines.suffix(3)) { line in
                    SubtitleLineRow(line: line, displayMode: store.effectiveDisplayMode,
                                    fontSize: store.fontSize,
                                    speakerName: store.displayName(for: line.speaker))
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
