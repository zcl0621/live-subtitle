import Foundation

/// 编排声纹归属:终句样本 → Float 转换 → 抽 embedding → 聚类 → SpeakerID。
///
/// 并发设计:SpeakerClusterer 非线程安全,由本 actor 在 init 里自建自持,
/// 生命周期不出 actor,Swift 6 下无需 @unchecked Sendable。音频切片
/// (AudioRingBuffer,同样非 Sendable)留在 TranscriptionPipeline actor 内,
/// 调用方先 `pipeline.sliceAudio(seconds:)` 拿到 Sendable 的 [Int16] 再传进来。
actor SpeakerAttributor {
    /// P6c 实测标定值(probes/RESULTS.md §P6c),**这三个常量是全工程的真值来源**:
    /// SubtitleStore 的设置默认值、文档里引用的数字都指向这里。改它们之前先看那一节。
    static let defaultThresholdMe: Float = 0.60
    static let defaultThresholdCluster: Float = 0.50
    /// P6d 重标(2026-08-15):原为 4.0s,真机日志显示那把 78% 的终句挡在判定之外,
    /// 全靠「沿用上一句身份」撑着。P6d 实测异人余弦最高只到 0.404,**任何句长下硬错都是 0**
    /// (认不成「我」、并不到别人头上),降下限只多一点软错(2.0s 时同人被拆 6%)。
    static let defaultMinDuration: Double = 2.0

    private let extractor: any VoiceprintExtractor
    private let clusterer: SpeakerClusterer
    /// 低于此时长不抽 embedding,沿用上一句身份。定值与推翻过的假设见 probes/RESULTS.md §P6d:
    /// 关键是**异人余弦在任何句长下都够不着阈值**(最高 0.404),所以这个下限管的不是「会不会认错人」,
    /// 而是「会不会把同一个人拆成两个说话人」—— 一个软退化,不是硬错。
    /// 也**别再想着按 me/cluster 拆成两个下限**:P6d 实测两条路径的分布几乎重合,拆了反而会让
    /// 自己 2–4 秒的句子跳过「我」的比对被标成「说话人 N」。
    private let minDuration: Double
    /// 本场定格的阈值。clusterer 自己也存了一份用于判定,这两个是对外可读的同一批值
    /// —— 供调用方/测试核对「设置页改的数到底有没有传进来」,不必撬开 clusterer。
    nonisolated let thresholdMe: Float
    nonisolated let thresholdCluster: Float
    /// 每轨上一次成功判定的身份;短句/切片失效时沿用(说话人通常不会一句一换)。
    private var lastIdentity: [Track: SpeakerID] = [:]

    init(extractor: any VoiceprintExtractor,
         meProfiles: [[Float]],
         // P6c 定值(替代 P6a 的 0.70/0.60):P6a 是「整段 vs 整段」标定的,
         // 而真实链路是「多窗平均的注册档案 × 会话里一条几秒的终句」——
         // 后者同人余弦系统性偏低(5s 句最低 0.677),0.70 会把自己判成别人。
         // 异人最高只有 0.42,故下调仍有充足余量,且保持 θ_me > θ_cluster 的不对称。
         // 这里的默认值是「没人传就用实测标定值」的兜底;真实链路由 CaptionEngine
         // 从 SubtitleStore 传入用户在设置页调过的值(区间与不对称约束在 store 侧守)。
         thresholdMe: Float = SpeakerAttributor.defaultThresholdMe,
         thresholdCluster: Float = SpeakerAttributor.defaultThresholdCluster,
         minDuration: Double = SpeakerAttributor.defaultMinDuration) {
        self.extractor = extractor
        self.thresholdMe = thresholdMe
        self.thresholdCluster = thresholdCluster
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
            let fallback = lastIdentity[track] ?? .unresolved(track)
            lslog(String(format: "  判定跳过 [%@] 时长%.2fs(下限%.1fs) pcm=%@ → 回退 %@",
                         track.rawValue, duration, minDuration,
                         pcm.map { "\($0.count)样本" } ?? "nil",
                         String(describing: fallback.kind)))
            return fallback
        }
        do {
            let embedding = try await extractor.embed(PCMConvert.int16ToFloat(pcm))
            let id = clusterer.assign(embedding, track: track)
            lastIdentity[track] = id
            return id
        } catch {
            lslog("  判定失败 [\(track.rawValue)] 抽取抛错:\(error) → unresolved")
            return .unresolved(track)
        }
    }

    /// 清空聚类簇与每轨记忆。
    ///
    /// ⚠️ **不要把它接回 `CaptionEngine.stop()`** —— 那正是它被摘掉的地方。会话边界靠生命周期
    /// 守:attributor 是 per-engine 的 let,下一场是全新 engine + 全新 clusterer,簇号自然从 0 重编。
    /// 在 stop 里调则会与还在途的归属 Task 抢跑,把最后一句判在空 clusterer 上(理由写在 stop 里)。
    /// 保留本方法是给"原地复用一个 attributor 开下一场"的将来用的,今天没有这种调用方。
    func reset() {
        clusterer.reset()
        lastIdentity.removeAll()
    }
}
