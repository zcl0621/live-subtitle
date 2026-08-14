import Foundation

/// 把一整段注册录音变成一条声纹向量。
///
/// **为什么不直接 `embed(整段)`:** WeSpeaker 的输入窗口是 10s(`FluidAudioExtractor.embed`
/// 显式截到 `FluidAudioExtractor.windowSamples`),直接喂一段 25s 的录音等于把后 15s 扔掉
/// —— 那 P6a「档案要 ≥20s 语音」这条要求就白提了,用户读满整段文字也没换来更稳的档案。
/// 故切成模型窗口大小的片段逐段抽取,再取平均并重新 L2 归一化。
///
/// 平均后归一化是 `SpeakerClusterer.update(cluster:with:)` 更新簇心的同一套做法:
/// 同一个人的若干条已归一化向量取质心,仍落在同一向量空间,聚类阈值(θ_me 默认 0.60,
/// P6c 实测定值)不受影响,且比任何单窗都更稳(单窗会被那 10s 里的语调/内容带偏)。
enum VoiceprintEnrollment {
    enum EnrollError: Error, Equatable {
        case empty                // 没有可用样本
        case dimensionMismatch    // 各窗维度不一致(模型换了/实现出错)
        case degenerate           // 平均结果是零向量或非有限值
    }

    /// 模型窗口:10s @ 16kHz。**直接取自抽取器,不另写一份字面量** ——
    /// 窗口长度是模型的属性,而本文件的整个设计前提就是「切出来的窗恰好等于 embed 的
    /// 截断长度」。两处各写一个 160_000 时,换模型的人只改抽取器那一处,注册端就会
    /// 悄悄喂进超长窗、在 embed 内被二次截断:不报错,但每一条档案都变弱。
    static let windowSamples = FluidAudioExtractor.windowSamples

    /// 尾巴短于 5s 就并不进来单独成窗。P6a 衰减表:3s 前缀与整段的余弦已到 0.905,
    /// 更短的窗向量明显偏移,单独算一票会把平均值拉歪。唯一例外是整段本来就很短
    /// (录制闸门已挡在 15s,这里只是防御)。
    static let minTailSamples = 80_000

    /// 切窗。返回的区间不重叠、按序覆盖到最后一个够长的尾巴。
    static func windows(sampleCount: Int) -> [Range<Int>] {
        guard sampleCount > 0 else { return [] }
        guard sampleCount > windowSamples else { return [0..<sampleCount] }
        var result: [Range<Int>] = []
        var start = 0
        while start < sampleCount {
            let end = min(start + windowSamples, sampleCount)
            // 太短的尾巴丢弃;但至少要留下一个窗(整段 ≤ 一窗时上面已提前返回)
            if end - start >= minTailSamples { result.append(start..<end) }
            start = end
        }
        return result
    }

    /// 逐窗抽 embedding → 平均 → L2 归一化。任一窗抽取失败即整体失败
    /// (注册是一次性动作,宁可让用户重录,也不要悄悄用半份数据存一条弱档案)。
    static func embedding(
        for pcm: [Int16],
        using extractor: any VoiceprintExtractor
    ) async throws -> [Float] {
        let floats = PCMConvert.int16ToFloat(pcm)
        let ranges = windows(sampleCount: floats.count)
        guard !ranges.isEmpty else { throw EnrollError.empty }

        var sum: [Float] = []
        for range in ranges {
            let e = try await extractor.embed(Array(floats[range]))
            guard !e.isEmpty else { throw EnrollError.empty }
            if sum.isEmpty {
                sum = e
            } else {
                guard sum.count == e.count else { throw EnrollError.dimensionMismatch }
                for i in sum.indices { sum[i] += e[i] }
            }
        }
        guard let normalized = FluidAudioExtractor.l2Normalized(sum) else {
            throw EnrollError.degenerate
        }
        return normalized
    }
}
