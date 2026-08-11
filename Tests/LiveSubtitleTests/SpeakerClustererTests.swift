import XCTest
@testable import LiveSubtitle

final class SpeakerClustererTests: XCTestCase {
    /// 造 L2 归一化向量:d 维,第 i 维为 1,其余 0(彼此正交,余弦=0)
    private func basis(_ i: Int, _ d: Int = 8) -> [Float] {
        var v = [Float](repeating: 0, count: d); v[i] = 1; return v
    }
    /// 两基向量的归一化混合,用于造「相似但不相同」
    private func blend(_ a: [Float], _ b: [Float], _ t: Float) -> [Float] {
        let v = zip(a, b).map { $0 * (1 - t) + $1 * t }
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / n }
    }

    func testMatchesEnrolledMeAboveThreshold() {
        let c = SpeakerClusterer(meProfiles: [basis(0)], thresholdMe: 0.75, thresholdCluster: 0.70)
        XCTAssertEqual(c.assign(basis(0), track: .mic).kind, .me)
    }

    func testDistinctVoiceBecomesNewCluster() {
        let c = SpeakerClusterer(meProfiles: [basis(0)], thresholdMe: 0.75, thresholdCluster: 0.70)
        XCTAssertEqual(c.assign(basis(1), track: .system).kind, .cluster(0))
        XCTAssertEqual(c.assign(basis(2), track: .system).kind, .cluster(1))
    }

    func testSimilarVoiceJoinsExistingCluster() {
        let c = SpeakerClusterer(meProfiles: [], thresholdMe: 0.75, thresholdCluster: 0.70)
        XCTAssertEqual(c.assign(basis(1), track: .system).kind, .cluster(0))
        // 与 basis(1) 余弦 ≈0.95,应归入同簇而非新建
        XCTAssertEqual(c.assign(blend(basis(1), basis(2), 0.2), track: .system).kind, .cluster(0))
    }

    /// θ_me > θ_cluster 的不对称必须生效:落在两阈值之间的向量不算「我」
    func testBetweenThresholdsIsNotMe() {
        let c = SpeakerClusterer(meProfiles: [basis(0)], thresholdMe: 0.95, thresholdCluster: 0.70)
        let near = blend(basis(0), basis(1), 0.25)   // 与 basis(0) 余弦 ≈0.93
        XCTAssertNotEqual(c.assign(near, track: .mic).kind, .me)
    }

    func testMeRecognizedOnBothTracks() {
        let c = SpeakerClusterer(meProfiles: [basis(0)], thresholdMe: 0.75, thresholdCluster: 0.70)
        XCTAssertEqual(c.assign(basis(0), track: .mic).kind, .me)
        // 外放漏音场景:我的声音出现在系统音轨,仍应认出是我
        XCTAssertEqual(c.assign(basis(0), track: .system).kind, .me)
    }

    func testMultipleMeProfilesTakeMax() {
        // 中英两份档案,命中任意一份即算「我」
        let c = SpeakerClusterer(meProfiles: [basis(0), basis(3)], thresholdMe: 0.75, thresholdCluster: 0.70)
        XCTAssertEqual(c.assign(basis(3), track: .mic).kind, .me)
    }

    func testCentroidUpdateKeepsUnitNorm() {
        let c = SpeakerClusterer(meProfiles: [], thresholdMe: 0.75, thresholdCluster: 0.70)
        _ = c.assign(basis(1), track: .system)
        _ = c.assign(blend(basis(1), basis(2), 0.1), track: .system)
        let norm = sqrt(c.centroids[0].reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 1e-4)
    }

    func testResetClearsClustersButKeepsMe() {
        let c = SpeakerClusterer(meProfiles: [basis(0)], thresholdMe: 0.75, thresholdCluster: 0.70)
        _ = c.assign(basis(1), track: .system)
        c.reset()
        XCTAssertTrue(c.centroids.isEmpty)
        XCTAssertEqual(c.assign(basis(0), track: .mic).kind, .me)
    }
}
