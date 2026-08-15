import XCTest

@testable import LiveSubtitle

/// 退避闸门的不变量。它守的是「翻译整场失效时别每句话都去重建 session」——
/// 写错了不报错、不崩,只会在最糟的时候(语言包真没了)把每一句都拖慢一次
/// prepareTranslation,而那恰恰是用户已经在抱怨的场景。
final class TranslationRetryGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testFreshGateAllowsRetry() {
        XCTAssertTrue(TranslationRetryGate().canRetry(now: t0))
    }

    func testBlockedGateRefusesWithinCooldown() {
        var g = TranslationRetryGate()
        g.block(now: t0)
        XCTAssertFalse(g.canRetry(now: t0), "刚退避就该拦住")
        XCTAssertFalse(g.canRetry(now: t0.addingTimeInterval(TranslationRetryGate.cooldown - 0.1)))
    }

    func testGateReopensExactlyAtCooldownBoundary() {
        var g = TranslationRetryGate()
        g.block(now: t0)
        XCTAssertTrue(g.canRetry(now: t0.addingTimeInterval(TranslationRetryGate.cooldown)),
                      "到点即放行,不多等")
    }

    /// 一次成功要能立刻解除退避 —— 否则临时故障恢复后还要白等 30s。
    func testClearReopensImmediately() {
        var g = TranslationRetryGate()
        g.block(now: t0)
        g.clear()
        XCTAssertTrue(g.canRetry(now: t0))
    }

    /// 反复失败只是把静默期往后推,不会累积成越来越长的封锁。
    func testRepeatedBlocksDoNotCompound() {
        var g = TranslationRetryGate()
        g.block(now: t0)
        let later = t0.addingTimeInterval(TranslationRetryGate.cooldown)
        g.block(now: later)
        XCTAssertFalse(g.canRetry(now: later))
        XCTAssertTrue(g.canRetry(now: later.addingTimeInterval(TranslationRetryGate.cooldown)),
                      "第二次退避从它自己那一刻起算,不叠加")
    }
}
