import SwiftUI
import AppKit

/// 设置页:DeepSeek API Key + Obsidian vault 路径选择。
@MainActor
struct SettingsView: View {
    @Bindable var store: SubtitleStore

    var body: some View {
        Form {
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
