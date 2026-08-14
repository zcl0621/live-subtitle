import Foundation

/// 编排声纹归属:终句样本 → Float 转换 → 抽 embedding → 聚类 → SpeakerID。
///
/// 并发设计:SpeakerClusterer 非线程安全,由本 actor 在 init 里自建自持,
/// 生命周期不出 actor,Swift 6 下无需 @unchecked Sendable。音频切片
/// (AudioRingBuffer,同样非 Sendable)留在 TranscriptionPipeline actor 内,
/// 调用方先 `pipeline.sliceAudio(seconds:)` 拿到 Sendable 的 [Int16] 再传进来。
actor SpeakerAttributor {
    private let extractor: any VoiceprintExtractor
    private let clusterer: SpeakerClusterer
    /// 低于此时长不抽 embedding。P6c 实测(注册档案 × 会话短句,probes/RESULTS.md):
    /// 3s 句的同人最低余弦 0.485、异人最高 0.410 —— 间隔只剩 +0.075,判定已不可靠;
    /// 5s 句才回到 +0.272。故下限取 4.0s,更短的句子宁可沿用上一句身份。
    private let minDuration: Double
    /// 每轨上一次成功判定的身份;短句/切片失效时沿用(说话人通常不会一句一换)。
    private var lastIdentity: [Track: SpeakerID] = [:]

    init(extractor: any VoiceprintExtractor,
         meProfiles: [[Float]],
         // P6c 定值(替代 P6a 的 0.70/0.60):P6a 是「整段 vs 整段」标定的,
         // 而真实链路是「多窗平均的注册档案 × 会话里一条几秒的终句」——
         // 后者同人余弦系统性偏低(5s 句最低 0.677),0.70 会把自己判成别人。
         // 异人最高只有 0.42,故下调仍有充足余量,且保持 θ_me > θ_cluster 的不对称。
         thresholdMe: Float = 0.60,
         thresholdCluster: Float = 0.50,
         minDuration: Double = 4.0) {
        self.extractor = extractor
        self.clusterer = SpeakerClusterer(meProfiles: meProfiles,
                                          thresholdMe: thresholdMe,
                                          thresholdCluster: thresholdCluster)
        self.minDuration = minDuration
    }

    /// 判定一条终句是谁说的。pcm 为该 range 的切片(nil = 已被环形覆盖等)。
    /// 太短/无切片 → 沿用该轨上次身份;抽取失败 → unresolved(不污染 lastIdentity)。
    func attribute(track: Track, range: Range<Double>, pcm: [Int16]?) async -> SpeakerID {
        let duration = range.upperBound - range.lowerBound
        guard duration >= minDuration, let pcm, !pcm.isEmpty else {
            return lastIdentity[track] ?? .unresolved(track)
        }
        do {
            let embedding = try await extractor.embed(PCMConvert.int16ToFloat(pcm))
            let id = clusterer.assign(embedding, track: track)
            lastIdentity[track] = id
            return id
        } catch {
            return .unresolved(track)
        }
    }

    /// 会话结束调:清空聚类簇与每轨记忆,别把这场会议的人带进下一场。
    func reset() {
        clusterer.reset()
        lastIdentity.removeAll()
    }
}
