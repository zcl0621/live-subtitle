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

            Section("说话人判定阈值") {
                thresholdRow("认作「我」 θ_me", value: $store.thresholdMe)
                thresholdRow("并入同一说话人 θ_cluster", value: $store.thresholdCluster)
                Text(store.isRunning
                     ? "字幕运行中不可调整,停止后再改(判定器在开始那一刻按阈值构建)。"
                     : """
                       实测依据:同一个人最低约 0.68、不同人最高约 0.42(详见 probes/RESULTS.md)。\
                       θ_me 调低 = 更容易把一句话认成「我」;θ_cluster 调低 = 更容易把两个人并成一个,\
                       调高则同一个人容易被拆成多个「说话人 N」。θ_me 始终高于 θ_cluster —— \
                       把别人认成「我」比漏认自己更糟,所以把 θ_me 调到 θ_cluster 头上时,后者会跟着降。
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
