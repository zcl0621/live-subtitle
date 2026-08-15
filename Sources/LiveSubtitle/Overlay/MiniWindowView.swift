import SwiftUI

/// 小窗:全部历史 + 竖向滚动,新句自动滚到底。复用 SubtitleLineRow。
/// 点说话人标签可改名(字幕条是点击穿透的浮窗,改名只在这里做)。
struct MiniWindowView: View {
    var store: SubtitleStore
    /// 正在改名的说话人;nil = 没在改。
    @State private var renaming: SpeakerID?
    @State private var draftName: String = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let target = renaming {
                renameBar(target)
                    // 取焦必须等 TextField 真的进了视图树。在 beginRename 里写
                    // `nameFieldFocused = true` 是同一次更新内的事,那会儿这条 bar 还没插进来,
                    // 焦点绑定没有落点、被直接丢弃 —— 改名条弹出来却没有光标,敲字进不去、⏎ 也不提交。
                    // `.id(target)`:改名途中点了别的说话人时强制重建,好让 onAppear 再跑一次。
                    .id(target)
                    .onAppear { nameFieldFocused = true }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.lines) { line in
                            SubtitleLineRow(line: line, displayMode: store.effectiveDisplayMode,
                                            fontSize: store.fontSize,
                                            speakerName: store.displayName(for: line.speaker),
                                            onTapSpeaker: beginRename)
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
        }
        .frame(minWidth: 260, maxWidth: .infinity, minHeight: 180, maxHeight: .infinity)
        .background(.black.opacity(store.opacity), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12)))
    }

    /// 改名条走内联而不是 popover/sheet:小窗是 borderless 的 NSPanel,
    /// 弹出层在这种窗口上定位与取焦都不稳,内联一条最不容易出岔子。
    @ViewBuilder private func renameBar(_ target: SpeakerID) -> some View {
        HStack(spacing: 6) {
            Text(target.displayName)      // 默认名做锚点,让用户知道在改谁
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(target.color)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            TextField("改成…", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($nameFieldFocused)
                .onSubmit { commitRename(target) }
            Button("好") { commitRename(target) }.controlSize(.small)
            Button("取消") { cancelRename() }.controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.white.opacity(0.08))
    }

    private func beginRename(_ speaker: SpeakerID) {
        renaming = speaker
        // 已改过就带出现有的名字直接改;没改过留空,占位符提示默认名会被顶掉
        draftName = store.speakerNames[speaker.kind] ?? ""
        // 取焦交给 renameBar 的 onAppear —— 这里设了也没用,理由写在那儿
    }

    /// 空名 = 恢复默认(store.rename 负责),不是存一个空标签。
    private func commitRename(_ target: SpeakerID) {
        store.rename(target, to: draftName)
        cancelRename()
    }

    private func cancelRename() {
        renaming = nil
        draftName = ""
        nameFieldFocused = false
    }
}
