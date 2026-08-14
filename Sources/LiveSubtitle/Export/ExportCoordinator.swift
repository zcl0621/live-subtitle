import Foundation

/// 把当前会话的转录整理(可选 DeepSeek 总结)后写入 Obsidian vault。
/// 独立于 CaptionEngine/toggle 逻辑,仅在菜单“整理并导出到 Obsidian”触发。
@MainActor
enum ExportCoordinator {

    /// 执行一次导出,返回给 UI 显示的中文状态文本。
    static func exportToObsidian(store: SubtitleStore) async -> String {
        // 一次会议一篇笔记:只收最后一场的行(lines 跨会话不清空,见 SubtitleStore.beginSession)
        let finalLines = ObsidianExporter.lastSessionLines(store.lines).filter { $0.isFinal }
        guard !finalLines.isEmpty else {
            return "没有可导出的转录"
        }
        // 被排除的是更早那些场次的行。不静默丢掉这个事实:用户按下导出时脑子里可能装着
        // 整个 app 运行期的字幕,状态栏得说清这一篇里没有它们。
        let skipped = store.lines.filter { $0.isFinal }.count - finalLines.count

        let transcript = ObsidianExporter.transcriptMarkdown(from: finalLines,
                                                             speakerNames: store.speakerNames)
        let apiKey = store.deepSeekAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let vaultPath = store.obsidianVaultPath
        let now = Date()

        // ① 总结:有 key 就调 DeepSeek,失败/无 key 回退到默认 title/summary。
        let title: String
        let summary: String
        if !apiKey.isEmpty {
            do {
                let result = try await DeepSeekClient(apiKey: apiKey).summarize(transcript: transcript)
                title = result.title
                summary = result.summary
            } catch {
                title = fallbackTitle(now)
                summary = "(DeepSeek 总结失败:\(shortReason(error)),已跳过)"
            }
        } else {
            title = fallbackTitle(now)
            summary = "(未配置 DeepSeek,略过总结)"
        }

        // ② 写盘:后台执行,避免阻塞主线程。
        let note = ObsidianExporter.Note(
            title: title,
            summary: summary,
            transcriptMarkdown: transcript,
            date: now
        )
        do {
            let url = try await Task.detached { try ObsidianExporter.write(note, toVaultPath: vaultPath) }.value
            let suffix = skipped > 0 ? "(仅本场;更早 \(skipped) 行属于上一场,未收入)" : ""
            return "已导出: \(url.lastPathComponent)\(suffix)"
        } catch let error as LocalizedError {
            return error.errorDescription ?? "导出失败"
        } catch {
            return "导出失败: \(error.localizedDescription)"
        }
    }

    /// 无 DeepSeek 时的回退标题:只用时刻(日期已在文件名前缀里,避免重复)。
    /// 失败原因的简短可读描述(区分坏 key / 网络 / 限流等),不塞 http body 长串。
    private static func shortReason(_ error: Error) -> String {
        if let e = error as? DeepSeekClient.DeepSeekError {
            switch e {
            case .missingKey: return "未配置 key"
            case .http(let code, _): return "HTTP \(code)"
            case .badResponse: return "响应异常"
            }
        }
        return (error as NSError).localizedDescription   // 网络类(超时/断网等)
    }

    private static func fallbackTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
