import SwiftUI
import AppKit

/// 设置页:会议语种 + DeepSeek API Key + Obsidian vault 路径选择。
@MainActor
struct SettingsView: View {
    @Bindable var store: SubtitleStore
    /// 字幕是否正在运行。运行中禁改语种:识别器在开始那一刻按语种构建,中途换不了。
    var isRunning: Bool = false

    var body: some View {
        Form {
            Section("会议") {
                Picker("会议语种", selection: $store.meetingLanguage) {
                    ForEach(MeetingLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .disabled(isRunning)
                Text(isRunning
                     ? "字幕运行中不可切换,停止后再改。"
                     : "一个会议只有一种语言。中文会议只出原文,不做翻译。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
