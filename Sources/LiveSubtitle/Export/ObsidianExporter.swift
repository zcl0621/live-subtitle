import Foundation

/// 把一次会话的转录 + DeepSeek 总结导出为一个 Obsidian vault 里的 .md 文件。
enum ObsidianExporter {

    struct Note {
        let title: String
        let summary: String
        let transcriptMarkdown: String
        let date: Date
    }

    enum ExportError: LocalizedError {
        case emptyVaultPath
        case vaultNotFound(String)

        var errorDescription: String? {
            switch self {
            case .emptyVaultPath:
                return "未设置 Obsidian vault 路径"
            case .vaultNotFound(let path):
                return "Obsidian vault 目录不存在:\(path)"
            }
        }
    }

    /// 从字幕行生成转录 markdown(只收 isFinal 的行)。
    /// 每行: "- **我/对方**:原文" 若有译文再 " — 译文"。
    static func transcriptMarkdown(from lines: [SubtitleLine]) -> String {
        lines
            .filter { $0.isFinal }
            .map { line in
                let speaker = displayName(for: line.speaker)
                var row = "- **\(speaker)**:\(line.original)"
                if let translated = line.translated,
                   !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    row += " — \(translated)"
                }
                return row
            }
            .joined(separator: "\n")
    }

    /// 写入 <vaultPath>/<yyyy-MM-dd>-<sanitized title>.md,返回写入的 URL。
    @discardableResult
    static func write(_ note: Note, toVaultPath vaultPath: String) throws -> URL {
        let trimmedVault = vaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVault.isEmpty else {
            throw ExportError.emptyVaultPath
        }

        let vaultURL = URL(fileURLWithPath: trimmedVault, isDirectory: true)
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: vaultURL.path, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw ExportError.vaultNotFound(trimmedVault)
        }

        let base = "\(fileDateString(note.date))-\(sanitize(note.title))"
        let fileURL = uniqueFileURL(in: vaultURL, base: base)

        let content = fileContent(for: note)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

    /// 避免覆盖同名笔记:<base>.md 已存在则退到 <base>-2.md / -3.md …
    private static func uniqueFileURL(in dir: URL, base: String) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent("\(base).md", isDirectory: false)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(n).md", isDirectory: false)
            n += 1
        }
        return candidate
    }

    // MARK: - Helpers

    // Task 8 会替换成真身份文案;当前按轨给出与旧 Speaker 一致的显示
    private static func displayName(for speaker: SpeakerID) -> String {
        switch speaker.track {
        case .mic: return "我"
        case .system: return "对方"
        }
    }

    private static func sanitize(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "未命名" }

        let illegal: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        var cleaned = String(trimmed.map { illegal.contains($0) ? "-" : $0 })
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)

        if cleaned.count > 60 {
            cleaned = String(cleaned.prefix(60))
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名" : cleaned
    }

    private static func fileDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func frontmatterDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private static func fileContent(for note: Note) -> String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "未命名"
            : note.title.trimmingCharacters(in: .whitespacesAndNewlines)

        var out = "---\n"
        out += "title: \(yamlScalar(title))\n"
        out += "date: \(frontmatterDateString(note.date))\n"
        out += "tags: [livesubtitle]\n"
        out += "source: LiveSubtitle\n"
        out += "---\n"
        out += "\n## 总结\n\n"
        out += note.summary
        out += "\n\n## 转录\n\n"
        out += note.transcriptMarkdown
        return out
    }

    /// title 一律用双引号包裹并完整转义(反斜杠/引号/换行/回车/制表符)。
    /// 双引号 scalar 不会被 YAML 当成列表(- )、块(| >)、锚点(& *)、指示符(@ ` ! ?)等解析,
    /// 也不会因内嵌换行断开 frontmatter,因此对 DeepSeek 返回的任意 title 都安全。
    private static func yamlScalar(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return "\"\(escaped)\""
    }
}
