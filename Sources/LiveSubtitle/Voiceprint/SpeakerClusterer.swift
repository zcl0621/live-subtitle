import Foundation

/// 会话内在线说话人聚类。先比预注册的「我」,再比已有簇,都不中则新建簇。
/// 输入 embedding 必须已 L2 归一化(P6a 实测 FluidAudio 原始输出并非严格归一化,
/// 由 VoiceprintExtractor 实现负责归一化后再传入 —— 见 plan Task 5)。
/// 非线程安全;整个实例须留在单一 actor/队列内(Task 6 接线时确认)。
final class SpeakerClusterer {
    private let meProfiles: [[Float]]
    private let thresholdMe: Float
    private let thresholdCluster: Float
    private(set) var centroids: [[Float]] = []
    private var counts: [Int] = []

    init(meProfiles: [[Float]], thresholdMe: Float, thresholdCluster: Float) {
        self.meProfiles = meProfiles
        self.thresholdMe = thresholdMe
        self.thresholdCluster = thresholdCluster
    }

    func assign(_ embedding: [Float], track: Track) -> SpeakerID {
        // 1) 先看是不是「我」——中英两份档案取 max
        let meScore = meProfiles.map { Self.cosine($0, embedding) }.max() ?? -1
        if meScore >= thresholdMe {
            return SpeakerID(track: track, kind: .me)
        }
        // 2) 再看归入哪个已有簇
        var bestIdx = -1
        var bestScore = -Float.infinity
        for (i, c) in centroids.enumerated() {
            let s = Self.cosine(c, embedding)
            if s > bestScore { bestScore = s; bestIdx = i }
        }
        if bestIdx >= 0, bestScore >= thresholdCluster {
            update(cluster: bestIdx, with: embedding)
            return SpeakerID(track: track, kind: .cluster(bestIdx))
        }
        // 3) 新建簇
        centroids.append(embedding)
        counts.append(1)
        return SpeakerID(track: track, kind: .cluster(centroids.count - 1))
    }

    func reset() { centroids.removeAll(); counts.removeAll() }

    /// 滑动平均更新簇中心后重新 L2 归一化(否则余弦尺度会漂)。
    private func update(cluster i: Int, with e: [Float]) {
        let n = Float(counts[i])
        var merged = zip(centroids[i], e).map { ($0 * n + $1) / (n + 1) }
        let norm = sqrt(merged.reduce(0) { $0 + $1 * $1 })
        if norm > 0 { merged = merged.map { $0 / norm } }
        centroids[i] = merged
        counts[i] += 1
    }

    /// 两个已归一化向量的余弦 = 点积。长度不等按较短者截断(防御性)。
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        assert(a.count == b.count, "embedding 维度不一致:\(a.count) vs \(b.count)")
        let n = min(a.count, b.count)
        var dot: Float = 0
        for i in 0..<n { dot += a[i] * b[i] }
        return dot
    }
}
