import XCTest

@testable import LiveSubtitle

/// 可控假抽取器 —— VoiceprintExtractor 协议接缝专为此留(见 Task 5 注释)。
private struct MockExtractor: VoiceprintExtractor {
    struct Boom: Error {}
    enum Behavior: Sendable {
        case success([Float])
        case failure
    }
    let behavior: Behavior

    func embed(_ samples: [Float]) async throws -> [Float] {
        switch behavior {
        case .success(let v): return v
        case .failure: throw Boom()
        }
    }
}

/// 有状态假抽取器:按调用顺序逐个消费 behavior,耗尽后一律失败。
private actor SequenceExtractor: VoiceprintExtractor {
    private var behaviors: [MockExtractor.Behavior]
    init(_ behaviors: [MockExtractor.Behavior]) { self.behaviors = behaviors }

    func embed(_ samples: [Float]) async throws -> [Float] {
        guard !behaviors.isEmpty else { throw MockExtractor.Boom() }
        switch behaviors.removeFirst() {
        case .success(let v): return v
        case .failure: throw MockExtractor.Boom()
        }
    }
}

final class SpeakerAttributorTests: XCTestCase {
    /// 4 维单位向量(维度对聚类逻辑无所谓,余弦只看方向)。
    private static func unit(_ hot: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 4)
        v[hot] = 1
        return v
    }
    /// 3s @16k 的假样本(内容无所谓,mock 不看)。
    private static let pcm3s = [Int16](repeating: 1000, count: 48000)

    /// 判定逻辑的测试显式注入 minDuration,不吃默认值 —— 这些用例测的是
    /// 「够长就抽取、太短就回退」的行为,不该在阈值调参时集体失灵。
    /// 默认值本身由 `testDefaultsMatchProbeCalibration` 单独钉住。
    private func makeAttributor(_ behavior: MockExtractor.Behavior,
                                meProfiles: [[Float]] = [],
                                minDuration: Double = 2.0) -> SpeakerAttributor {
        SpeakerAttributor(extractor: MockExtractor(behavior: behavior),
                          meProfiles: meProfiles,
                          minDuration: minDuration)
    }

    // MARK: - 短句 / 切片失效回退

    func testShortUtteranceWithoutHistoryIsUnresolved() async {
        let a = makeAttributor(.success(Self.unit(0)))
        let id = await a.attribute(track: .system, range: 0.0..<1.0,
                                   pcm: [Int16](repeating: 0, count: 16000))
        XCTAssertEqual(id, .unresolved(.system))
    }

    func testShortUtteranceReusesLastIdentity() async {
        let a = makeAttributor(.success(Self.unit(0)))
        let first = await a.attribute(track: .system, range: 0.0..<3.0, pcm: Self.pcm3s)
        XCTAssertEqual(first.kind, .cluster(0))
        let second = await a.attribute(track: .system, range: 3.0..<4.0, pcm: nil)  // 短句
        XCTAssertEqual(second, first)   // 沿用上次身份
    }

    func testEmptyPcmSliceFallsBack() async {
        let a = makeAttributor(.success(Self.unit(0)))
        // 非 nil 但空数组的切片同样走回退(!pcm.isEmpty 分支)
        let id = await a.attribute(track: .system, range: 0.0..<3.0, pcm: [])
        XCTAssertEqual(id, .unresolved(.system))
    }

    func testNilSliceLongUtteranceFallsBack() async {
        let a = makeAttributor(.success(Self.unit(0)))
        // 时长够但切片拿不到(已被环形覆盖)→ 同样走回退
        let id = await a.attribute(track: .mic, range: 0.0..<5.0, pcm: nil)
        XCTAssertEqual(id, .unresolved(.mic))
    }

    func testLastIdentityIsPerTrack() async {
        let a = makeAttributor(.success(Self.unit(0)))
        _ = await a.attribute(track: .system, range: 0.0..<3.0, pcm: Self.pcm3s)
        let micShort = await a.attribute(track: .mic, range: 3.0..<4.0, pcm: nil)
        XCTAssertEqual(micShort, .unresolved(.mic))   // 不串轨
    }

    // MARK: - 抽取失败

    func testExtractionFailureReturnsUnresolved() async {
        let a = makeAttributor(.failure)
        let id = await a.attribute(track: .mic, range: 0.0..<3.0, pcm: Self.pcm3s)
        XCTAssertEqual(id, .unresolved(.mic))
    }

    func testExtractionFailureDoesNotPolluteLastIdentity() async {
        let a = makeAttributor(.failure)
        _ = await a.attribute(track: .mic, range: 0.0..<3.0, pcm: Self.pcm3s)
        let short = await a.attribute(track: .mic, range: 3.0..<4.0, pcm: nil)
        XCTAssertEqual(short, .unresolved(.mic))   // 失败不算「上次身份」
    }

    func testFailureAfterSuccessReturnsUnresolvedNotLastIdentity() async {
        // 刻意的不对称,钉死别被"顺手统一"掉:短句/无切片是「没有新证据」,
        // 沿用上次身份合理;抽取失败是「有证据但坏了」,宁可不标(unresolved)
        // 也不拿旧身份冒充这句的判定结果。
        let a = SpeakerAttributor(
            extractor: SequenceExtractor([.success(Self.unit(0)), .failure]),
            meProfiles: [], minDuration: 2.0)
        let first = await a.attribute(track: .system, range: 0.0..<3.0, pcm: Self.pcm3s)
        XCTAssertEqual(first.kind, .cluster(0))
        let second = await a.attribute(track: .system, range: 3.0..<6.0, pcm: Self.pcm3s)
        XCTAssertEqual(second, .unresolved(.system))   // 不是 first
    }

    // MARK: - 成功路径

    func testMatchesMeProfile() async {
        let me = Self.unit(0)
        let a = makeAttributor(.success(me), meProfiles: [me])
        let id = await a.attribute(track: .mic, range: 0.0..<3.0, pcm: Self.pcm3s)
        XCTAssertEqual(id, SpeakerID(track: .mic, kind: .me))
    }

    func testNoMeProfileAssignsClusterAndRemembers() async {
        let a = makeAttributor(.success(Self.unit(1)))
        let first = await a.attribute(track: .system, range: 0.0..<3.0, pcm: Self.pcm3s)
        XCTAssertEqual(first, SpeakerID(track: .system, kind: .cluster(0)))
        // 同向量再来一句 → 同簇
        let second = await a.attribute(track: .system, range: 3.0..<6.0, pcm: Self.pcm3s)
        XCTAssertEqual(second, first)
    }

    func testExactlyMinDurationExtracts() async {
        let a = makeAttributor(.success(Self.unit(0)), minDuration: 2.0)
        let id = await a.attribute(track: .system, range: 0.0..<2.0,
                                   pcm: [Int16](repeating: 1, count: 32000))
        XCTAssertEqual(id.kind, .cluster(0))   // 恰好等于下限也走抽取,不回退
    }

    /// 钉住 P6c 标定的默认值。改这三个数之前先看 probes/RESULTS.md 的 P6c 章节:
    /// 它们是拿「多窗平均注册档案 × 会话短句」的实测分布定的,不是拍的。
    func testDefaultsMatchProbeCalibration() async {
        // 默认 minDuration=4.0:3s 的句子应走回退而非抽取
        let a = SpeakerAttributor(extractor: MockExtractor(behavior: .success(Self.unit(0))),
                                  meProfiles: [])
        let short = await a.attribute(track: .mic, range: 0.0..<3.0, pcm: Self.pcm3s)
        XCTAssertEqual(short.kind, .unresolved, "3s < 默认下限 4.0s,应回退而不是抽取")
        let long = await a.attribute(track: .mic, range: 0.0..<5.0,
                                     pcm: [Int16](repeating: 1000, count: 80000))
        XCTAssertEqual(long.kind, .cluster(0), "5s ≥ 默认下限,应走抽取")
        // 三个常量本身也钉住 —— 它们是设置页默认值与文档引用的真值来源
        XCTAssertEqual(SpeakerAttributor.defaultThresholdMe, 0.60, accuracy: 0.0001)
        XCTAssertEqual(SpeakerAttributor.defaultThresholdCluster, 0.50, accuracy: 0.0001)
        XCTAssertEqual(SpeakerAttributor.defaultMinDuration, 4.0, accuracy: 0.0001)
        XCTAssertGreaterThan(SpeakerAttributor.defaultThresholdMe,
                             SpeakerAttributor.defaultThresholdCluster,
                             "θ_me > θ_cluster 的不对称是 spec §2 的刻意设计")
    }

    /// 传进来的阈值要能读回来 —— CaptionEngine 的接线测试靠这两个属性核对。
    func testThresholdsAreReadableFromOutside() {
        let a = SpeakerAttributor(extractor: MockExtractor(behavior: .failure),
                                  meProfiles: [],
                                  thresholdMe: 0.72,
                                  thresholdCluster: 0.61)
        XCTAssertEqual(a.thresholdMe, 0.72, accuracy: 0.0001)
        XCTAssertEqual(a.thresholdCluster, 0.61, accuracy: 0.0001)
    }

    // MARK: - reset

    func testResetClearsClustersAndLastIdentity() async {
        let a = makeAttributor(.success(Self.unit(0)))
        _ = await a.attribute(track: .system, range: 0.0..<3.0, pcm: Self.pcm3s)
        await a.reset()
        let short = await a.attribute(track: .system, range: 3.0..<4.0, pcm: nil)
        XCTAssertEqual(short, .unresolved(.system))   // lastIdentity 已清
        let again = await a.attribute(track: .system, range: 4.0..<7.0, pcm: Self.pcm3s)
        XCTAssertEqual(again.kind, .cluster(0))       // 簇编号从 0 重新开始
    }
}
