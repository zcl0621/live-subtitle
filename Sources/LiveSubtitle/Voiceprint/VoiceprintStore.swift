import Foundation

struct VoiceprintProfile: Codable, Sendable, Equatable {
    enum Language: String, Codable, Sendable, CaseIterable { case chinese, english }
    let language: Language
    let embedding: [Float]
    let recordedAt: Date
    let durationSeconds: Double
    /// 产出该 embedding 的声纹模型(如 FluidAudioExtractor.modelID)。
    /// 换模型后旧档案向量空间不兼容,靠它识别并提示重录。
    /// Optional:旧 JSON 无此字段照常解码为 nil,免迁移。
    let modelID: String?

    init(
        language: Language,
        embedding: [Float],
        recordedAt: Date,
        durationSeconds: Double,
        modelID: String? = nil
    ) {
        self.language = language
        self.embedding = embedding
        self.recordedAt = recordedAt
        self.durationSeconds = durationSeconds
        self.modelID = modelID
    }

    /// 这份档案的向量还能不能喂给 `current` 这个模型的聚类。
    ///
    /// - 相等 → 兼容。
    /// - `nil` → **当作兼容**。该字段是 Task 5 之后才加的,在它之前落盘的档案全部产自
    ///   `wespeaker_v2`(当时代码里只有这一个实现),向量空间与现在相同;把它们判成不兼容
    ///   等于凭空要求所有老用户重录一遍,收益为零。
    /// - 不等的非 nil → **拒绝**。这是明确盖了另一个模型的章,向量空间不通用,
    ///   拿去算余弦得到的是无意义的数字,比没有档案更糟(会误判成「我」或把人拆成两簇)。
    func isCompatible(withModelID current: String) -> Bool {
        modelID == nil || modelID == current
    }
}

/// 「我」的声纹档案(中/英各一份)。存 Application Support,不进 UserDefaults
/// ——256 维 Float 数组不适合塞 defaults,且未来要扩成多人档案库。
final class VoiceprintStore {
    private let fileURL: URL
    private(set) var profiles: [VoiceprintProfile] = []

    init(directory: URL? = nil) throws {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            dir = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("LiveSubtitle", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("voiceprints.json")
        load()
    }

    /// 同语言档案覆盖(重录即替换)。落盘失败则回滚内存态,
    /// 避免界面显示「已录制」而重启后又消失。
    func save(_ profile: VoiceprintProfile) throws {
        let snapshot = profiles
        profiles.removeAll { $0.language == profile.language }
        profiles.append(profile)
        do { try persist() } catch {
            profiles = snapshot
            throw error
        }
    }

    func remove(language: VoiceprintProfile.Language) throws {
        let snapshot = profiles
        profiles.removeAll { $0.language == language }
        do { try persist() } catch {
            profiles = snapshot
            throw error
        }
    }

    /// 供 SpeakerClusterer 用的 embedding 列表(两份都给,匹配时取 max)。
    var meEmbeddings: [[Float]] { profiles.map(\.embedding) }

    /// 只取与 `modelID` 兼容的档案(接线时用这个,不要用上面那个不过滤的)。
    /// 换模型后旧档案的向量空间不同,喂进聚类会让阈值判定失去意义。
    func meEmbeddings(modelID: String) -> [[Float]] {
        profiles.filter { $0.isCompatible(withModelID: modelID) }.map(\.embedding)
    }

    /// 存在但与当前模型不兼容的档案语言 —— UI 据此提示「换了模型,这份要重录」。
    func staleLanguages(modelID: String) -> [VoiceprintProfile.Language] {
        profiles.filter { !$0.isCompatible(withModelID: modelID) }.map(\.language)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([VoiceprintProfile].self, from: data)
        else { return }   // 首次运行 / 文件损坏 → 空档案,不崩
        profiles = decoded
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(profiles)
        try data.write(to: fileURL, options: .atomic)
    }
}
