import Foundation

struct VoiceprintProfile: Codable, Sendable, Equatable {
    enum Language: String, Codable, Sendable, CaseIterable { case chinese, english }
    let language: Language
    let embedding: [Float]
    let recordedAt: Date
    let durationSeconds: Double
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

    /// 同语言档案覆盖(重录即替换)。
    func save(_ profile: VoiceprintProfile) throws {
        profiles.removeAll { $0.language == profile.language }
        profiles.append(profile)
        try persist()
    }

    func remove(language: VoiceprintProfile.Language) throws {
        profiles.removeAll { $0.language == language }
        try persist()
    }

    /// 供 SpeakerClusterer 用的 embedding 列表(两份都给,匹配时取 max)。
    var meEmbeddings: [[Float]] { profiles.map(\.embedding) }

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
