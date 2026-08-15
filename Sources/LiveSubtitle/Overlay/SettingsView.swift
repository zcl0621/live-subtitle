import SwiftUI
import AppKit

/// 设置页:会议语种 + 我的声纹 + DeepSeek API Key + Obsidian vault 路径选择。
@MainActor
struct SettingsView: View {
    @Bindable var store: SubtitleStore

    var body: some View {
        Form {
            Section("会议") {
                Picker("会议语种", selection: $store.meetingLanguage) {
                    ForEach(MeetingLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                // 运行中禁改:识别器在开始那一刻按语种构建,中途换不了。
                .disabled(store.isRunning)
                Text(store.isRunning
                     ? "字幕运行中不可切换,停止后再改。"
                     : "一个会议只有一种语言。中文会议只出原文,不做翻译。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VoiceprintSection()

            Section("说话人判定") {
                // 这根滑杆管的是【判多少句】,下面两根管的是【怎么判】—— 真机上前者才是主要矛盾:
                // 4.0s 时 18 条终句只有 4 条进了判定(P6d)。放在最上面,因为多数人要调的是它。
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("最短判定句长")
                        Spacer()
                        Text(String(format: "%.1f 秒", store.minUtteranceSeconds))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: $store.minUtteranceSeconds,
                           in: SubtitleStore.minUtteranceRange,
                           step: SubtitleStore.minUtteranceStep)
                        .disabled(store.isRunning)
                }
                thresholdRow("认作「我」 θ_me", value: $store.thresholdMe)
                thresholdRow("并入同一说话人 θ_cluster", value: $store.thresholdCluster)
                Text(store.isRunning
                     ? "字幕运行中不可调整,停止后再改(判定器在开始那一刻按这三个值构建)。"
                     : """
                       短于「最短判定句长」的句子不跑声纹,沿用该轨上一句的身份。\
                       调低 = 判定覆盖更多句子,但同一个人更容易被拆成多个「说话人 N」;\
                       调高 = 更多句子靠沿用上一句,说话人换得勤时就会连着标错一串。\
                       实测(probes/RESULTS.md §P6d):不同人的余弦最高只到 0.40,\
                       够不着下面两个阈值 —— 所以调这根滑杆改变的是覆盖率,不会让别人被认成「我」。

                       θ_me 调低 = 更容易把一句话认成「我」;θ_cluster 调低 = 更容易把两个人并成一个,\
                       调高则同一个人容易被拆成多个。θ_me 始终高于 θ_cluster —— 把别人认成「我」\
                       比漏认自己更糟,所以把 θ_me 调到 θ_cluster 头上时,后者会跟着降。
                       """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("DeepSeek") {
                SecureField("DeepSeek API Key", text: $store.deepSeekAPIKey)
                    .textFieldStyle(.roundedBorder)
            }

            Section("Obsidian") {
                HStack(alignment: .firstTextBaseline) {
                    Text("Vault 路径")
                    Spacer()
                    Text(vaultDisplayPath)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(store.obsidianVaultPath)
                }
                Button("选择文件夹…") { chooseVaultFolder() }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
    }

    /// 一行阈值:标题 + 当前值 + 滑杆。运行中置灰 —— 与语种 Picker 同一套语义
    /// (SpeakerAttributor 在 CaptionEngine.init 那一刻按阈值构建,中途换不了)。
    @ViewBuilder private func thresholdRow(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value,
                   in: SubtitleStore.thresholdRange,
                   step: SubtitleStore.thresholdStep)
                .disabled(store.isRunning)
        }
    }

    private var vaultDisplayPath: String {
        let trimmed = store.obsidianVaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "未选择" : trimmed
    }

    private func chooseVaultFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择 Obsidian vault 文件夹"
        if panel.runModal() == .OK, let url = panel.url {
            store.obsidianVaultPath = url.path
        }
    }
}
