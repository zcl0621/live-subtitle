import Foundation
@preconcurrency import Translation

@MainActor
final class TranslationService {
    private var session: TranslationSession?

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

    /// 单句英→中。返回中文;失败返回 nil(调用方回退显示原文)。
    func translate(_ en: String) async -> String? {
        guard let s = session else { return nil }
        return try? await s.translate(en).targetText
    }
}
