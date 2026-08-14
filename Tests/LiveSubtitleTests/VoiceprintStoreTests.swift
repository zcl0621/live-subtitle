import XCTest
@testable import LiveSubtitle

final class VoiceprintStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceprintStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    private func makeProfile(
        _ language: VoiceprintProfile.Language,
        embedding: [Float] = [0.1, 0.2, 0.3],
        duration: Double = 12.5
    ) -> VoiceprintProfile {
        VoiceprintProfile(
            language: language,
            embedding: embedding,
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: duration
        )
    }

    // 1. 空档案初始化:目录里无文件 → profiles 空,不抛错
    func testInitWithEmptyDirectoryHasNoProfiles() throws {
        let store = try VoiceprintStore(directory: tempDir)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertTrue(store.meEmbeddings(modelID: "wespeaker_v2").isEmpty)
    }

    // 2. 存中文档案 → profiles 有 1 份
    func testSaveChineseProfile() throws {
        let store = try VoiceprintStore(directory: tempDir)
        try store.save(makeProfile(.chinese))
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.language, .chinese)
    }

    // 3. 重开实例(同 directory)→ 能读回
    func testProfilePersistsAcrossInstances() throws {
        let profile = makeProfile(.chinese, embedding: [1, 2, 3], duration: 8)
        do {
            let store = try VoiceprintStore(directory: tempDir)
            try store.save(profile)
        }
        let reopened = try VoiceprintStore(directory: tempDir)
        XCTAssertEqual(reopened.profiles, [profile])
    }

    // 4. 同语言重录覆盖 → 仍只有 1 份,内容是新的
    func testSaveSameLanguageOverwrites() throws {
        let store = try VoiceprintStore(directory: tempDir)
        try store.save(makeProfile(.chinese, embedding: [1, 1, 1]))
        let newer = makeProfile(.chinese, embedding: [9, 9, 9], duration: 20)
        try store.save(newer)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first, newer)
        // 覆盖后的状态也要落盘
        let reopened = try VoiceprintStore(directory: tempDir)
        XCTAssertEqual(reopened.profiles, [newer])
    }

    // 5. 中英各 1 份共存 → meEmbeddings 两个向量
    func testChineseAndEnglishCoexist() throws {
        let store = try VoiceprintStore(directory: tempDir)
        try store.save(makeProfile(.chinese, embedding: [1, 0, 0]))
        try store.save(makeProfile(.english, embedding: [0, 1, 0]))
        XCTAssertEqual(store.profiles.count, 2)
        let embeddings = store.meEmbeddings(modelID: "wespeaker_v2")
        XCTAssertEqual(embeddings.count, 2)
        XCTAssertTrue(embeddings.contains([1, 0, 0]))
        XCTAssertTrue(embeddings.contains([0, 1, 0]))
    }

    // 6. 删除 → 对应语言消失且持久化(重开实例确认)
    func testRemoveLanguagePersists() throws {
        do {
            let store = try VoiceprintStore(directory: tempDir)
            try store.save(makeProfile(.chinese))
            try store.save(makeProfile(.english))
            try store.remove(language: .chinese)
            XCTAssertEqual(store.profiles.map(\.language), [.english])
        }
        let reopened = try VoiceprintStore(directory: tempDir)
        XCTAssertEqual(reopened.profiles.map(\.language), [.english])
    }

    // 6b. 删除不存在的语言:no-op,不抛错
    func testRemoveMissingLanguageIsNoOp() throws {
        let store = try VoiceprintStore(directory: tempDir)
        try store.save(makeProfile(.english))
        try store.remove(language: .chinese)
        XCTAssertEqual(store.profiles.map(\.language), [.english])
    }

    // 8. modelID 完整往返:存 → 重开实例读回,字段不丢
    func testModelIDRoundTrips() throws {
        let profile = VoiceprintProfile(
            language: .chinese,
            embedding: [1, 2, 3],
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 8,
            modelID: FluidAudioExtractor.modelID
        )
        do {
            let store = try VoiceprintStore(directory: tempDir)
            try store.save(profile)
        }
        let reopened = try VoiceprintStore(directory: tempDir)
        XCTAssertEqual(reopened.profiles, [profile])
        XCTAssertEqual(reopened.profiles.first?.modelID, "wespeaker_v2")
    }

    // 8b. 旧 schema JSON(无 modelID 字段)照常解码,modelID 为 nil,免迁移
    func testOldSchemaWithoutModelIDStillDecodes() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let file = tempDir.appendingPathComponent("voiceprints.json")
        // recordedAt 用 JSONEncoder 默认策略(秒,自参考日期起)
        let oldJSON = """
        [{"language":"english","embedding":[1,0,0],"recordedAt":700000000,"durationSeconds":12.5}]
        """
        try Data(oldJSON.utf8).write(to: file)
        let store = try VoiceprintStore(directory: tempDir)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.profiles.first?.language, .english)
        XCTAssertNil(store.profiles.first?.modelID)
    }

    // 7b. 合法 JSON 但 schema 不对(非数组)→ 同样降级为空档案
    func testWrongSchemaJSONDegradesToEmpty() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let file = tempDir.appendingPathComponent("voiceprints.json")
        try Data("{}".utf8).write(to: file)
        let store = try VoiceprintStore(directory: tempDir)
        XCTAssertTrue(store.profiles.isEmpty)
    }

    // MARK: - modelID 兼容性过滤(不需要 CoreML,纯字段判定)

    private func profile(_ language: VoiceprintProfile.Language,
                         modelID: String?,
                         embedding: [Float]) -> VoiceprintProfile {
        VoiceprintProfile(language: language, embedding: embedding,
                          recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
                          durationSeconds: 22, modelID: modelID)
    }

    // 9a. 盖了当前模型的章 → 兼容
    func testMatchingModelIDIsCompatible() {
        let p = profile(.chinese, modelID: "wespeaker_v2", embedding: [1, 0, 0])
        XCTAssertTrue(p.isCompatible(withModelID: "wespeaker_v2"))
        XCTAssertTrue(p.isCompatible(withModelID: FluidAudioExtractor.modelID))
    }

    // 9b. nil(该字段出现之前落盘的老档案)→ 当作兼容,不逼老用户重录
    func testNilModelIDIsTreatedAsLegacyCompatible() {
        let p = profile(.chinese, modelID: nil, embedding: [1, 0, 0])
        XCTAssertTrue(p.isCompatible(withModelID: "wespeaker_v2"))
    }

    // 9c. 明确盖了别的模型的章 → 拒绝(向量空间不通用,算出来的余弦无意义)
    func testMismatchingModelIDIsRejected() {
        let p = profile(.chinese, modelID: "campplus_v1", embedding: [1, 0, 0])
        XCTAssertFalse(p.isCompatible(withModelID: "wespeaker_v2"))
    }

    // 9d. meEmbeddings(modelID:) 只放行兼容档案
    func testMeEmbeddingsFiltersByModelID() throws {
        let store = try VoiceprintStore(directory: tempDir)
        try store.save(profile(.chinese, modelID: "wespeaker_v2", embedding: [1, 0, 0]))
        try store.save(profile(.english, modelID: "campplus_v1", embedding: [0, 1, 0]))

        let filtered = store.meEmbeddings(modelID: "wespeaker_v2")
        XCTAssertEqual(filtered, [[1, 0, 0]])
        // 盘上确实是两份,只是其中一份被挡在聚类之外(不是没存进去)
        XCTAssertEqual(store.profiles.count, 2)
    }

    // 9e. nil 档案也会被 meEmbeddings(modelID:) 放行
    func testMeEmbeddingsKeepsLegacyNilProfiles() throws {
        let store = try VoiceprintStore(directory: tempDir)
        try store.save(profile(.chinese, modelID: nil, embedding: [1, 0, 0]))
        try store.save(profile(.english, modelID: "wespeaker_v2", embedding: [0, 1, 0]))
        XCTAssertEqual(store.meEmbeddings(modelID: "wespeaker_v2").count, 2)
    }

    // 9f. 全部不兼容 → 一条都不放行(退化成「没有档案」:仍能聚类,只是没人判成 .me)
    func testAllIncompatibleYieldsNoEmbeddings() throws {
        let store = try VoiceprintStore(directory: tempDir)
        try store.save(profile(.chinese, modelID: "campplus_v1", embedding: [1, 0, 0]))
        XCTAssertTrue(store.meEmbeddings(modelID: "wespeaker_v2").isEmpty)
        // 盘上那份还在,只是不参与聚类;UI 侧的「要重录」提示走 VoiceprintRecorder.isStale
        XCTAssertEqual(store.profiles.count, 1)
    }

    // 7. 损坏 JSON 不崩溃且降级为空档案
    func testCorruptFileDegradesToEmpty() throws {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let file = tempDir.appendingPathComponent("voiceprints.json")
        try Data([0xDE, 0xAD, 0xBE, 0xEF]).write(to: file)
        let store = try VoiceprintStore(directory: tempDir)
        XCTAssertTrue(store.profiles.isEmpty)
        // 降级后仍可正常保存,覆盖掉损坏文件
        try store.save(makeProfile(.chinese))
        let reopened = try VoiceprintStore(directory: tempDir)
        XCTAssertEqual(reopened.profiles.count, 1)
    }
}
