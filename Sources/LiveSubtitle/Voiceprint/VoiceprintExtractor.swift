import CoreML
import FluidAudio
import Foundation

/// 抽声纹向量。**独立成 protocol 是有意的架构对冲**:
/// 若换模型(如 CAM++),只需替换本实现,聚类/档案/UI 全不动。
/// (P6a 已判 GO,WeSpeaker 够用;此接缝保留作保险。)
protocol VoiceprintExtractor: Sendable {
    /// 输入 16kHz 单声道 Float32;输出 L2 归一化 256 维向量。
    func embed(_ samples: [Float]) async throws -> [Float]
}

/// Int16 → Float32 归一化。FormatConverter 产出 Int16,声纹模型要 Float32。
enum PCMConvert {
    static func int16ToFloat(_ samples: [Int16]) -> [Float] {
        samples.map { Float($0) / 32768.0 }
    }
}

/// FluidAudio(WeSpeaker v2)实现,走 P6a 验证过的轻量路径:
/// 稳态只把 wespeaker_v2.mlmodelc 载入内存(0.07s),mask 帧数从 embedding
/// 模型自己的输入形状读取(P6a 实测与完整路径余弦 1.000000)。
/// 首次下载时 FluidAudio 内部会短暂载两个模型(downloadIfNeeded 的副作用),
/// 模型已在盘上时跳过该调用,segmentation 模型完全不碰。
///
/// ⚠️ P6a 实测模型原始输出并非 L2 归一化(L2≈1.037),而 SpeakerClusterer.cosine
/// 是纯点积 —— 本实现必须归一化后再返回,否则阈值判定整体偏移。
///
/// `prepare()` 是显式异步调用:首次会下载模型(~13MB,一次性)+ ~3s CoreML 预热,
/// 调用方(Task 6)应放后台 Task 里跑,失败非致命 —— 未 prepare 时 embed 抛
/// `notPrepared`,字幕主链路照常走,说话人保持 `.unresolved`。幂等,可重复调用。
actor FluidAudioExtractor: VoiceprintExtractor {
    enum ExtractError: Error {
        case notPrepared
        case badModel
        case empty
        case degenerateEmbedding
    }

    /// 当前声纹模型标识,存进 VoiceprintProfile.modelID:换模型后旧档案
    /// 向量空间不兼容,靠这个字段识别并提示重录(Task 8 保存档案时盖章)。
    static let modelID = "wespeaker_v2"

    /// 模型输入窗口:10s @ 16kHz。超过这个长度 `embed` 就截断。
    /// 这是模型的属性,故由抽取器持有;`VoiceprintEnrollment` 的切窗读的是同一个常量
    /// (它切窗的前提正是「一窗 = 一次 embed 的全部输入」)。
    static let windowSamples = 160_000

    private var extractor: EmbeddingExtractor?
    private var maskFrames = 0
    private var inflightPrepare: Task<Void, Error>?

    /// 下载(如需)+ 加载 embedding 模型 + 一次哑元推理吃掉 ~3s CoreML 预热。
    /// 幂等:已就绪直接返回;进行中的并发调用共享同一次准备(actor 在 await
    /// 处可重入,不去重会重复下载+预热)。失败后可重试。
    func prepare() async throws {
        guard extractor == nil else { return }
        if let inflight = inflightPrepare {
            return try await inflight.value
        }
        let task = Task { try await doPrepare() }
        inflightPrepare = task
        defer { inflightPrepare = nil }
        try await task.value
    }

    private func doPrepare() async throws {
        // 模型已在盘上就不走 downloadIfNeeded —— 它除了下载还会把两个模型
        // 都载进内存,稳态启动没必要付这份加载
        if Self.findModel(
            named: ModelNames.Diarizer.embeddingFile,
            under: DiarizerModels.defaultModelsDirectory()) == nil {
            _ = try await DiarizerModels.downloadIfNeeded()
        }

        guard
            let modelURL = Self.findModel(
                named: ModelNames.Diarizer.embeddingFile,
                under: DiarizerModels.defaultModelsDirectory())
        else { throw ExtractError.badModel }

        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try MLModel(contentsOf: modelURL, configuration: config)

        // mask 帧数不硬编码,读模型自己的输入形状(P6a:shape[1] = 589)
        guard
            let maskShape = model.modelDescription.inputDescriptionsByName["mask"]?
                .multiArrayConstraint?.shape,
            maskShape.count >= 2, maskShape[1].intValue > 0
        else { throw ExtractError.badModel }

        let frames = maskShape[1].intValue
        let ex = EmbeddingExtractor(embeddingModel: model)

        // 预热:3s 低幅正弦哑元推理(与 P6a 探针 smoke 信号一致),
        // 让首句真实调用只花 ~49ms 而非 ~3s
        let warmup = (0..<48000).map { Float(sin(Double($0) * 2 * .pi * 220 / 16000)) * 0.3 }
        let mask = [Float](repeating: 1.0, count: frames)
        _ = try ex.getEmbeddings(audio: warmup, masks: [mask])

        self.extractor = ex
        self.maskFrames = frames
    }

    func embed(_ samples: [Float]) async throws -> [Float] {
        guard let extractor, maskFrames > 0 else { throw ExtractError.notPrepared }
        guard !samples.isEmpty else { throw ExtractError.empty }

        // 模型窗口 10s(@16kHz);超长句取前 10s,不让尾部被隐式截断方式左右
        let audio = samples.count > Self.windowSamples
            ? Array(samples.prefix(Self.windowSamples))
            : samples

        let mask = [Float](repeating: 1.0, count: maskFrames)
        let embeddings = try extractor.getEmbeddings(audio: audio, masks: [mask])
        guard let raw = embeddings.first, !raw.isEmpty else { throw ExtractError.empty }
        guard let normalized = Self.l2Normalized(raw) else {
            throw ExtractError.degenerateEmbedding
        }
        return normalized
    }

    /// L2 归一化;零向量/非有限值返回 nil。独立成 static 便于不装模型就能单测。
    static func l2Normalized(_ v: [Float]) -> [Float]? {
        let norm = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return v.map { $0 / norm }
    }

    /// 先试标准位置(defaultModelsDirectory 直下);不在再从 ModelHub 仓库根
    /// (defaultModelsDirectory 的父目录)递归找 —— 模型可能在子目录里。
    private static func findModel(named: String, under root: URL) -> URL? {
        let direct = root.appendingPathComponent(named)
        if FileManager.default.fileExists(atPath: direct.path) { return direct }

        let searchRoot = root.deletingLastPathComponent()
        guard
            let enumerator = FileManager.default.enumerator(
                at: searchRoot, includingPropertiesForKeys: nil)
        else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == named {
            return url
        }
        return nil
    }
}
