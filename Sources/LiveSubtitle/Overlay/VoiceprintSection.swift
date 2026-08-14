import SwiftUI

/// 设置页「我的声纹」区块:中/英各一个槽位,录制 / 重录 / 删除,录制时显示朗读文本、
/// 已录时长与实时电平。自己持有 `VoiceprintRecorder`(录音 + 档案库都在里头)。
@MainActor
struct VoiceprintSection: View {
    @State private var recorder = VoiceprintRecorder()

    var body: some View {
        Section("我的声纹") {
            if let error = recorder.storeError {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            ForEach(VoiceprintProfile.Language.allCases, id: \.self) { language in
                slot(language)
            }

            if recorder.isRecording || recorder.phase == .preparing {
                recordingPanel
            }
            if recorder.phase == .processing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在提取声纹…(首次要下载模型,可能要等一会儿)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            banner

            Text("录一段自己的声音,字幕里就能把你说的话标成「我」。中英各录一份,分别在对应语种的会议里生效;录完下一场字幕开始时生效。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // 档案库在这里才打开:recorder 的 init 是空的(见 VoiceprintRecorder 里的说明)。
        .task { recorder.loadIfNeeded() }
    }

    // MARK: - 槽位

    @ViewBuilder private func slot(_ language: VoiceprintProfile.Language) -> some View {
        let profile = recorder.profile(for: language)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(language.displayName).frame(width: 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(status(profile)).font(.caption).foregroundStyle(.secondary)
                if let profile, recorder.isStale(profile) {
                    Text("声纹模型已更换,这份档案不再生效 —— 请重录。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            Button(profile == nil ? "录制" : "重录") {
                recorder.clearMessage()
                recorder.start(language: language)
            }
            .disabled(recorder.isBusy || recorder.storeError != nil)
            if profile != nil {
                Button("删除") {
                    recorder.clearMessage()
                    recorder.delete(language: language)
                }
                .disabled(recorder.isBusy)
            }
        }
    }

    private func status(_ profile: VoiceprintProfile?) -> String {
        guard let profile else { return "未录制" }
        return String(format: "已录制 · %.0f 秒 · %@",
                      profile.durationSeconds,
                      profile.recordedAt.formatted(date: .abbreviated, time: .shortened))
    }

    // MARK: - 录制中面板

    @ViewBuilder private var recordingPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if recorder.phase == .preparing {
                Text("正在打开麦克风…").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("请用平常语气、正常语速朗读下面这段话:")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(VoiceprintPrompt.text(for: recorder.language ?? .chinese))
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 120)

                HStack {
                    // 向下取整:14.6s 显示成 15 秒却按不动「保存」最招骂
                    Text("\(Int(recorder.elapsed)) 秒")
                        .font(.system(size: 13, weight: .medium)).monospacedDigit()
                    Text(hint).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
                levelMeter

                HStack {
                    Button("保存") { recorder.finishAndSave() }
                        .buttonStyle(.borderedProminent)
                        // 闸门:P6a 的档案样本都在 22s 以上,短样本向量不稳,
                        // 存下来会时灵时不灵,比没有档案更难排查。
                        .disabled(!recorder.canSaveNow)
                    Button("取消") { recorder.cancel() }
                    Spacer()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var hint: String {
        let elapsed = recorder.elapsed
        if !recorder.canSaveNow {
            // 向上取整:还差 0.4 秒时显示「还差 1 秒」,不显示「还差 0 秒」却按不动保存
            let remaining = Int((VoiceprintRecorder.minimumSeconds - elapsed).rounded(.up))
            return "还差 \(max(1, remaining)) 秒才能保存"
        }
        if elapsed < VoiceprintRecorder.recommendedSeconds {
            return "可以保存了,读满 \(Int(VoiceprintRecorder.recommendedSeconds)) 秒更稳"
        }
        return "时长够了,读完这段就可以保存"
    }

    @ViewBuilder private var levelMeter: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    // 贴近满刻度 = 削波,提示用户离远点说
                    .fill(recorder.level > 0.95 ? Color.red : Color.green)
                    .frame(width: max(2, geo.size.width * recorder.level))
            }
        }
        .frame(height: 6)
        .accessibilityLabel("输入电平")
    }

    @ViewBuilder private var banner: some View {
        switch recorder.phase {
        case .message(let text):
            Text(text).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .failure(let text):
            Text(text).font(.caption).foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        default:
            EmptyView()
        }
    }
}

/// 注册用朗读语料。取自 P6a 探针语料(`probes/p6a_voiceprint/samples/朗读文本.md`)各一段,
/// **在此内联一份**:probes/ 不随 app 分发,运行时读不到那个文件。
/// 每段正常语速约 25–30s,读完即超过 20s 的建议时长。
enum VoiceprintPrompt {
    static func text(for language: VoiceprintProfile.Language) -> String {
        switch language {
        case .chinese:
            """
            周末我去了一趟城西的旧书市场,淘到几本七十年代的科普杂志。摊主是位退休的中学老师,\
            聊起来才知道他收了三十多年书,光是搬家就搬了四次。他说现在愿意翻纸质书的年轻人越来越少,\
            但每个周六早上,他还是雷打不动地出摊,风雨无阻。
            """
        case .english:
            """
            Last weekend I finally cleaned out the garage, and it turned into a whole afternoon \
            project. Behind the old bicycles I found a box of photographs from college, a broken \
            record player, and three umbrellas I thought I had lost years ago. Funny how much \
            history piles up in the corners of a house when you are not paying attention to it.
            """
        }
    }
}
