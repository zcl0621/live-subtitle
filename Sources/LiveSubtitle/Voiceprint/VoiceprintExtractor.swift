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
/// 只把 wespeaker_v2.mlmodelc 载入内存(0.07s),segmentation 模型完全不载,
/// mask 帧数从 embedding 模型自己的输入形状读取(P6a 实测两条路径余弦 1.000000)。
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
    }

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
        _ = try await DiarizerModels.downloadIfNeeded()

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

        let mask = [Float](repeating: 1.0, count: maskFrames)
        let embeddings = try extractor.getEmbeddings(audio: samples, masks: [mask])
        guard let raw = embeddings.first, !raw.isEmpty else { throw ExtractError.empty }
        guard let normalized = Self.l2Normalized(raw) else { throw ExtractError.empty }
        return normalized
    }

    /// L2 归一化;零向量/非有限值返回 nil。独立成 static 便于不装模型就能单测。
    static func l2Normalized(_ v: [Float]) -> [Float]? {
        let norm = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        guard norm > 0, norm.isFinite else { return nil }
        return v.map { $0 / norm }
    }

    /// defaultModelsDirectory 的父目录是 ModelHub 仓库根,模型可能在子目录,递归找。
    private static func findModel(named: String, under root: URL) -> URL? {
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
