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
        XCTAssertEqual(c.assign(basis(0)), .me)
    }

    func testDistinctVoiceBecomesNewCluster() {
        let c = SpeakerClusterer(meProfiles: [basis(0)], thresholdMe: 0.75, thresholdCluster: 0.70)
        XCTAssertEqual(c.assign(basis(1)), .cluster(0))   // 正交,余弦 0 < θ_new
        XCTAssertEqual(c.assign(basis(2)), .cluster(1))
    }

    func testSimilarVoiceJoinsExistingCluster() {
        let c = SpeakerClusterer(meProfiles: [], thresholdMe: 0.75, thresholdCluster: 0.70)
        XCTAssertEqual(c.assign(basis(1)), .cluster(0))
        // 与 basis(1) 余弦 ≈0.95,应归入同簇而非新建
        XCTAssertEqual(c.assign(blend(basis(1), basis(2), 0.2)), .cluster(0))
    }

    /// θ_me > θ_cluster 的不对称必须生效:落在两阈值之间的向量不算「我」
    func testBetweenThresholdsIsNotMe() {
        let c = SpeakerClusterer(meProfiles: [basis(0)], thresholdMe: 0.95, thresholdCluster: 0.70)
        let near = blend(basis(0), basis(1), 0.25)   // 与 basis(0) 余弦 ≈0.93
        // 落在两阈值之间:不算「我」,落回聚类分支成为第一个簇
        XCTAssertEqual(c.assign(near), .cluster(0))
    }

    func testMultipleMeProfilesTakeMax() {
        // 中英两份档案,命中任意一份即算「我」
        let c = SpeakerClusterer(meProfiles: [basis(0), basis(3)], thresholdMe: 0.75, thresholdCluster: 0.70)
        XCTAssertEqual(c.assign(basis(3)), .me)
    }

    func testCentroidUpdateKeepsUnitNorm() {
        let c = SpeakerClusterer(meProfiles: [], thresholdMe: 0.75, thresholdCluster: 0.70)
        _ = c.assign(basis(1))
        _ = c.assign(blend(basis(1), basis(2), 0.1))
        let norm = sqrt(c.centroids[0].reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 1e-4)
    }

    func testResetClearsClustersButKeepsMe() {
        let c = SpeakerClusterer(meProfiles: [basis(0)], thresholdMe: 0.75, thresholdCluster: 0.70)
        _ = c.assign(basis(1))
        c.reset()
        XCTAssertTrue(c.centroids.isEmpty)
        XCTAssertEqual(c.assign(basis(0)), .me)
    }

    // MARK: - 死区(Task 10 实测:同一个人相邻两句 0.857 / 0.248,后者被劈成新说话人)

    /// 落在 [θ_new, θ_cluster) 的向量既不并簇也不新建,交给调用方沿用上一句身份。
    func testDeadZoneReturnsUncertainInsteadOfNewCluster() {
        let c = SpeakerClusterer(meProfiles: [], thresholdMe: 0.75, thresholdCluster: 0.70,
                                 thresholdNew: 0.20)
        XCTAssertEqual(c.assign(basis(1)), .cluster(0))
        let murky = blend(basis(1), basis(2), 0.72)   // 与 basis(1) 余弦 ≈0.36,落在 [0.20, 0.70)
        XCTAssertEqual(c.assign(murky), .uncertain)
        XCTAssertEqual(c.centroids.count, 1, "死区不得新建簇")
    }

    /// 死区那一句**不能掺进簇心** —— 一个被污染的向量混进去会连累后面所有判定。
    func testDeadZoneDoesNotContaminateCentroid() {
        let c = SpeakerClusterer(meProfiles: [], thresholdMe: 0.75, thresholdCluster: 0.70,
                                 thresholdNew: 0.20)
        _ = c.assign(basis(1))
        let before = c.centroids[0]
        _ = c.assign(blend(basis(1), basis(2), 0.72))
        XCTAssertEqual(c.centroids[0], before, "死区句不得更新簇心")
    }

    /// 死区之下仍要能开新簇 —— 否则真来了新人就永远并进上一个人。
    func testBelowDeadZoneStillCreatesNewCluster() {
        let c = SpeakerClusterer(meProfiles: [], thresholdMe: 0.75, thresholdCluster: 0.70,
                                 thresholdNew: 0.20)
        _ = c.assign(basis(1))
        XCTAssertEqual(c.assign(basis(2)), .cluster(1), "余弦 0 < θ_new,是没见过的人")
    }

    /// 第一句没有任何簇可比,必须开张,不能因为「没匹配上」就悬着。
    func testFirstUtteranceAlwaysCreatesClusterEvenWithDeadZone() {
        let c = SpeakerClusterer(meProfiles: [], thresholdMe: 0.75, thresholdCluster: 0.70,
                                 thresholdNew: 0.20)
        XCTAssertEqual(c.assign(basis(1)), .cluster(0))
    }
}
