import Foundation
@preconcurrency import Translation

/// 重建 session 的退避闸门。抽成独立值类型只为一件事:**这段逻辑能不接 Apple 的
/// Translation 框架单测**。它管的是「别每句话都去重建 session」这条不变量 ——
/// 写错了不会报错,只会在语言包真没了的时候把每一句都拖慢一次 prepareTranslation。
struct TranslationRetryGate: Equatable {
    /// 重建失败后的静默期。装语言包是分钟级的人工动作,30s 内重试没有意义;
    /// 但也不能一次失败就永久放弃 —— 那正是 2026-08-15 要修的老毛病。
    static let cooldown: TimeInterval = 30

    private var blockedUntil: Date?

    func canRetry(now: Date) -> Bool {
        guard let blockedUntil else { return true }
        return now >= blockedUntil
    }

    mutating func block(now: Date) { blockedUntil = now.addingTimeInterval(Self.cooldown) }
    mutating func clear() { blockedUntil = nil }
}

@MainActor
final class TranslationService {
    private var session: TranslationSession?
    /// 串行化:final 与 volatile 可能并发调 translate,单个 TranslationSession 不保证并发安全,
    /// 用任务链把调用排队,保证同一 session 同一时刻只有一个 translate 在跑。
    private var queue: Task<String?, Never>?

    private var gate = TranslationRetryGate()
    /// 重建 session 后仍然翻不动 —— 供 UI 提示「去系统设置重下语言包」。
    private(set) var needsLanguagePackReinstall = false

    enum TranslateError: Error {
        case notInstalled
        case failed
    }

    /// 暖机:构造 session + prepareTranslation。语言包未装则抛 notInstalled。
    func warmUp() async throws {
        do {
            session = try await Self.makeSession()
        } catch {
            throw TranslateError.notInstalled
        }
    }

    /// 单句英→中。返回中文;失败返回 nil(调用方回退显示原文)。调用被串行排队。
    ///
    /// **失败后会重建一次 session 再试。** 这是本类的关键行为,别"顺手简化"掉:
    /// 实测(用户 2026-08-15 反馈)翻译会莫名其妙整场失效,必须去 系统设置 → 语言与地区 →
    /// 翻译语言 重新下载语言包才恢复。老实现是 `try? await s.translate(...)` —— 错误被吞掉、
    /// session 原样留着,于是**一次失效就永久失效**,这一场剩下的每句话都翻不出来。
    /// 换成"丢掉旧 session、重建一次再试",至少让它能自愈;真的是语言包没了,才退避 30s。
    func translate(_ en: String) async -> String? {
        let previous = queue
        let task = Task { @MainActor () -> String? in
            _ = await previous?.value          // 等前一个 translate 完成,避免并发访问 session
            return await self.translateSerially(en)
        }
        queue = task
        return await task.value
    }

    /// 已在串行链上,可以安全读写 session。
    private func translateSerially(_ en: String) async -> String? {
        // 空串没有翻译的必要,更不该因为它翻失败就去重建 session
        guard !en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        if let s = session, let out = try? await s.translate(en).targetText {
            return out
        }
        // 走到这里有两种情况:从没暖机成功过,或原来的 session 失效了。两种都靠重建解决。
        let now = Date()
        guard gate.canRetry(now: now) else { return nil }
        session = nil
        guard let fresh = try? await Self.makeSession() else {
            // 重建都失败 → 多半语言包真没了。退避,并让 UI 有机会给出可操作提示。
            gate.block(now: now)
            needsLanguagePackReinstall = true
            return nil
        }
        session = fresh
        gate.clear()
        guard let out = try? await fresh.translate(en).targetText else {
            // 新 session 也翻不动:不是"失效"能解释的,同样退避,别每句都重建。
            gate.block(now: now)
            return nil
        }
        needsLanguagePackReinstall = false
        return out
    }

    /// UI 取走提示后清零,免得同一条提示反复弹。
    func consumeReinstallHint() -> Bool {
        defer { needsLanguagePackReinstall = false }
        return needsLanguagePackReinstall
    }

    private static func makeSession() async throws -> TranslationSession {
        let s = TranslationSession(installedSource: Locale.Language(identifier: "en"),
                                   target: Locale.Language(identifier: "zh-Hans"))
        try await s.prepareTranslation()
        return s
    }
}
