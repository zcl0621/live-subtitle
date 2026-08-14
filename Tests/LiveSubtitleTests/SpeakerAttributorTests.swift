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

final class SpeakerAttributorTests: XCTestCase {
    /// 4 维单位向量(维度对聚类逻辑无所谓,余弦只看方向)。
    private static func unit(_ hot: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 4)
        v[hot] = 1
        return v
    }
    /// 3s @16k 的假样本(内容无所谓,mock 不看)。
    private static let pcm3s = [Int16](repeating: 1000, count: 48000)

    private func makeAttributor(_ behavior: MockExtractor.Behavior,
                                meProfiles: [[Float]] = []) -> SpeakerAttributor {
        SpeakerAttributor(extractor: MockExtractor(behavior: behavior), meProfiles: meProfiles)
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
        let a = makeAttributor(.success(Self.unit(0)))
        let id = await a.attribute(track: .system, range: 0.0..<2.0,
                                   pcm: [Int16](repeating: 1, count: 32000))
        XCTAssertEqual(id.kind, .cluster(0))   // >= 2.0s 走抽取,不回退
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
