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

    /// 一次导出只收【最后一场产出终句的会议】的行。
    ///
    /// `lines` 跨会话不清空(理由见 `SubtitleStore.beginSession`),而一次会议 = 一篇笔记:
    /// 混进上一场会写出三种错 —— 上一场英文会议的 ` — 译文` 尾巴混进中文会议的笔记;
    /// 下一场是全新 `SpeakerClusterer`(簇号从 0 重编),两场的「说话人 2」根本不是同一个人;
    /// 改名映射也只对本场有效 —— 且它作废的时刻就钉在本函数的锚点上
    /// (`SubtitleStore.renamesPendingExpiry`:本场第一条终句既挪锚点,也让上一场的改名失效)。
    ///
    /// 锚点取【最后一条终句】而非最后一行:新会议刚开、只有灰字中间态时,
    /// 该导出的仍是上一场那批终句,而不是"本场 0 行"。
    /// 用 filter 而非取尾部连续段,是不指望"同场的行一定连续"这条隐含前提。
    static func lastSessionLines(_ lines: [SubtitleLine]) -> [SubtitleLine] {
        guard let sessionID = lines.last(where: { $0.isFinal })?.sessionID else { return [] }
        return lines.filter { $0.sessionID == sessionID }
    }

    /// 从字幕行生成转录 markdown(只收 isFinal 的行)。
    /// 每行: "- **我 / 张三 / 说话人 2**:原文",有译文再接 " — 译文";
    /// 中文会议不产译文,行退化成 "- **说话人 1**:中文原文",不留空的 ` — ` 尾巴。
    ///
    /// 说话人名与屏上同源:`SpeakerID.displayName(overrides:)` + store 的改名映射
    /// (`speakerNames`),不再按轨压回「我/对方」——否则同一份数据会出现两套说法。
    static func transcriptMarkdown(from lines: [SubtitleLine],
                                   speakerNames: [SpeakerID.Kind: String] = [:]) -> String {
        lines
            .filter { $0.isFinal }
            .map { line in
                let speaker = line.speaker.displayName(overrides: speakerNames)
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
