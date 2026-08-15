import Foundation

/// 会话内在线说话人聚类。先比预注册的「我」,再比已有簇,都不中则新建簇。
/// 输入 embedding 必须已 L2 归一化(P6a 实测 FluidAudio 原始输出并非严格归一化,
/// 由 VoiceprintExtractor 实现负责归一化后再传入 —— 见 plan Task 5)。
/// 非线程安全;整个实例须留在单一 actor/队列内(Task 6 接线时确认)。
final class SpeakerClusterer {
    /// 判定结果。**不含 Track** —— 轨只用来拼最终的 `SpeakerID`,由调用方负责。
    /// 聚类器结构上看不见轨,也就structurally 不可能区别对待两条轨(外放漏音时
    /// 同一个人出现在麦克风轨还是系统音轨,必须落到同一个簇)。
    enum Assignment: Equatable {
        case me
        case cluster(Int)
        /// **死区**:既不像任何已有簇(< θ_cluster),又没低到能确信是个没见过的人(≥ θ_new)。
        /// 真机实测这种分数几乎都是「这一句本身坏了」——背景音乐、转场、抢话把 embedding 带偏,
        /// 而不是真来了个新人。此时新建簇 = 凭空造一个说话人(Task 10 实测:同一个人的
        /// 相邻两句拿到 0.857 和 0.248,后者当场被劈成「说话人 3」)。
        /// 交给调用方沿用上一句身份 —— 与短句兜底同一套「没有新证据就别改判」的逻辑。
        case uncertain
    }

    private let meProfiles: [[Float]]
    private let thresholdMe: Float
    private let thresholdCluster: Float
    private let thresholdNew: Float
    private(set) var centroids: [[Float]] = []
    private var counts: [Int] = []

    /// 新建簇的门槛:最高簇分低于此值才认定「确实是个没见过的人」。
    /// 0.20 取自 P6d + Task 10 实测:异人分数几乎都落在 0.08–0.14(实测两次新人分别是
    /// 0.098 / 0.080),而被污染的同人句落在 0.25 上下 —— 0.20 正好把两者切开。
    /// 不做成设置项:它与 θ_cluster 的可调下限(0.30)之间恒有余量,且真要调的是 θ_cluster。
    static let defaultThresholdNew: Float = 0.20

    init(meProfiles: [[Float]], thresholdMe: Float, thresholdCluster: Float,
         thresholdNew: Float = SpeakerClusterer.defaultThresholdNew) {
        self.meProfiles = meProfiles
        self.thresholdMe = thresholdMe
        self.thresholdCluster = thresholdCluster
        self.thresholdNew = thresholdNew
    }

    func assign(_ embedding: [Float]) -> Assignment {
        // 1) 先看是不是「我」——中英两份档案取 max
        let meScore = meProfiles.map { Self.cosine($0, embedding) }.max() ?? -1
        // 2) 再看归入哪个已有簇
        var bestIdx = -1
        var bestScore = -Float.infinity
        for (i, c) in centroids.enumerated() {
            let s = Self.cosine(c, embedding)
            if s > bestScore { bestScore = s; bestIdx = i }
        }
        lslog(String(format: "  判定 我档案=%d 份 meScore=%.3f(θ_me=%.2f) 已有%d簇 最高簇分=%@(θ_cluster=%.2f θ_new=%.2f)",
                     meProfiles.count, meScore, thresholdMe, centroids.count,
                     bestIdx >= 0 ? String(format: "%.3f→簇%d", bestScore, bestIdx) : "无",
                     thresholdCluster, thresholdNew))
        if meScore >= thresholdMe {
            lslog("  → 判为【我】")
            return .me
        }
        if bestIdx >= 0, bestScore >= thresholdCluster {
            update(cluster: bestIdx, with: embedding)
            lslog("  → 并入【说话人 \(bestIdx + 1)】")
            return .cluster(bestIdx)
        }
        // 3) 死区:像得不够、又不够陌生。多半是这一句坏了,别拿它造新人,
        //    也**别拿它更新任何簇心** —— 一个被污染的向量掺进簇心会连累后面所有判定。
        if bestIdx >= 0, bestScore >= thresholdNew {
            lslog("  → 落在死区(\(String(format: "%.3f", bestScore)) ∈ [\(thresholdNew), \(thresholdCluster)))" +
                  ",不新建簇,沿用上一句身份")
            return .uncertain
        }
        // 4) 新建簇。没有任何簇时(bestIdx < 0)也走这里 —— 第一句总得开张。
        centroids.append(embedding)
        counts.append(1)
        lslog("  → 新建【说话人 \(centroids.count)】")
        return .cluster(centroids.count - 1)
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
