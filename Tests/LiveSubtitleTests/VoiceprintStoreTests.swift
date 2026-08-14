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
        XCTAssertTrue(store.meEmbeddings.isEmpty)
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
        XCTAssertEqual(store.meEmbeddings.count, 2)
        XCTAssertTrue(store.meEmbeddings.contains([1, 0, 0]))
        XCTAssertTrue(store.meEmbeddings.contains([0, 1, 0]))
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
