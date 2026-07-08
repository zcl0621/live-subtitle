// P2 探针 — TranslationSession headless 英→中(macOS 26)
// go/no-go:1) headless 能否脱离 SwiftUI 构造并 translate  2) 语言包状态/能否装  3) 质量  4) 延迟
// 编译:swiftc -target arm64-apple-macos26.0 probes/p2_translation.swift -o /tmp/p2 && /tmp/p2
import Foundation
import Translation

let source = Locale.Language(identifier: "en")
let target = Locale.Language(identifier: "zh-Hans")

// —— 1. 语言包状态 ——
let avail = LanguageAvailability()
let status = await avail.status(from: source, to: target)
print("== P2 探针:TranslationSession headless 英→中 ==")
print("[1] LanguageAvailability status(en→zh-Hans): \(status)")

// —— 2. headless 构造 session(关键:脱离 SwiftUI) ——
let session = TranslationSession(installedSource: source, target: target)
print("[2] headless init 成功;canRequestDownloads = \(session.canRequestDownloads)")

// —— 3. prepareTranslation(可能触发下载 or 抛 notInstalled) ——
do {
    let t0 = ContinuousClock.now
    try await session.prepareTranslation()
    print("[3] prepareTranslation() OK,耗时 \(ContinuousClock.now - t0)")
} catch {
    print("[3] prepareTranslation() 抛错: \(error)")
}

// —— 4. 批量翻译 + 逐句延迟 ——
let sentences = [
    "Hey, can everyone hear me okay?",
    "Let's circle back to the roadmap after the standup.",
    "The API returned a 500 error on the staging environment.",
    "I think we should ship the MVP by end of Q3.",
    "Can you share your screen? I can't see the diagram.",
    "Our latency dropped from 1.5 seconds to under 300 milliseconds.",
    "Sorry, you're breaking up, could you repeat that?",
    "The quarterly revenue was up seventeen percent year over year.",
    "Let's take this offline and sync tomorrow morning.",
    "He said the deployment is blocked on the security review.",
    "Actually, I disagree — that approach doesn't scale.",
    "What's the ETA on the bug fix for the login flow?",
    "We need buy-in from stakeholders before we proceed.",
    "The transcription model runs entirely on device, no cloud.",
    "Give me a sec, I'm pulling up the numbers now.",
]

print("[4] 逐句翻译(延迟 / 原文 => 译文):")
var ok = 0, fail = 0
for s in sentences {
    do {
        let t0 = ContinuousClock.now
        let resp = try await session.translate(s)
        let dt = ContinuousClock.now - t0
        ok += 1
        print("    [\(dt)]  \(s)\n        => \(resp.targetText)")
    } catch {
        fail += 1
        print("    [ERR] \(s)\n        => \(error)")
    }
}
print("[5] 汇总:成功 \(ok) / 失败 \(fail) / 共 \(sentences.count)")
