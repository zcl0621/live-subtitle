import Foundation
@preconcurrency import Translation

@MainActor
final class TranslationService {
    private var session: TranslationSession?
    /// 串行化:final 与 volatile 可能并发调 translate,单个 TranslationSession 不保证并发安全,
    /// 用任务链把调用排队,保证同一 session 同一时刻只有一个 translate 在跑。
    private var queue: Task<String?, Never>?

    enum TranslateError: Error {
        case notInstalled
        case failed
    }

    /// 暖机:构造 session + prepareTranslation。语言包未装则抛 notInstalled。
    func warmUp() async throws {
        let s = TranslationSession(installedSource: Locale.Language(identifier: "en"),
                                    target: Locale.Language(identifier: "zh-Hans"))
        do {
            try await s.prepareTranslation()
        } catch {
            throw TranslateError.notInstalled
        }
        session = s
    }

    /// 单句英→中。返回中文;失败返回 nil(调用方回退显示原文)。调用被串行排队。
    func translate(_ en: String) async -> String? {
        let previous = queue
        let task = Task { @MainActor () -> String? in
            _ = await previous?.value          // 等前一个 translate 完成,避免并发访问 session
            guard let s = session else { return nil }
            return try? await s.translate(en).targetText
        }
        queue = task
        return await task.value
    }
}
