import XCTest
@testable import LiveSubtitle

/// 按顺序吐出预设向量的假抽取器,顺便记下每次收到的样本数 —— 不需要 CoreML。
private actor StubExtractor: VoiceprintExtractor {
    private var queue: [[Float]]
    private(set) var receivedCounts: [Int] = []
    private let failure: Error?

    init(returning: [[Float]], failure: Error? = nil) {
        self.queue = returning
        self.failure = failure
    }

    func embed(_ samples: [Float]) async throws -> [Float] {
        receivedCounts.append(samples.count)
        if let failure { throw failure }
        guard !queue.isEmpty else { return [1, 0, 0] }
        return queue.removeFirst()
    }

    func counts() -> [Int] { receivedCounts }
}

private struct StubError: Error {}

final class VoiceprintEnrollmentTests: XCTestCase {

    // MARK: - 切窗

    func testEmptyInputHasNoWindows() {
        XCTAssertTrue(VoiceprintEnrollment.windows(sampleCount: 0).isEmpty)
    }

    // 不足一窗 → 整段一窗(闸门已挡住太短的录音,这里只保证不丢数据)
    func testShorterThanOneWindowIsOneWindow() {
        XCTAssertEqual(VoiceprintEnrollment.windows(sampleCount: 240_000 / 2), [0..<120_000])
        XCTAssertEqual(VoiceprintEnrollment.windows(sampleCount: 160_000), [0..<160_000])
    }

    // 25s 录音 → 10s + 10s + 5s 三窗,全覆盖不重叠。
    // 这正是本类型存在的理由:单次 embed 只吃前 10s,直接 embed 会扔掉后 15s。
    func testTwentyFiveSecondsSplitsIntoThreeWindows() {
        let windows = VoiceprintEnrollment.windows(sampleCount: 400_000)   // 25s @16k
        XCTAssertEqual(windows, [0..<160_000, 160_000..<320_000, 320_000..<400_000])
    }

    // 短尾巴(<5s)丢弃:P6a 衰减表显示 3s 以下的向量已明显偏移,会把平均值拉歪
    func testShortTailIsDropped() {
        let windows = VoiceprintEnrollment.windows(sampleCount: 160_000 + 16_000)   // 10s + 1s
        XCTAssertEqual(windows, [0..<160_000])
    }

    func testTailAtExactlyMinimumIsKept() {
        let windows = VoiceprintEnrollment.windows(sampleCount: 160_000 + 80_000)   // 10s + 5s
        XCTAssertEqual(windows, [0..<160_000, 160_000..<240_000])
    }

    // 窗与窗首尾相接、不重叠、不越界
    func testWindowsAreContiguousAndInBounds() {
        for count in [1, 79_999, 160_001, 333_333, 1_920_000] {
            let windows = VoiceprintEnrollment.windows(sampleCount: count)
            var cursor = 0
            for w in windows {
                XCTAssertEqual(w.lowerBound, cursor, "窗之间有缝或重叠 (count=\(count))")
                XCTAssertLessThanOrEqual(w.upperBound, count)
                cursor = w.upperBound
            }
        }
    }

    // MARK: - 平均

    // 逐窗抽取 → 平均 → 重新 L2 归一化
    func testAveragesEmbeddingsAcrossWindowsAndNormalizes() async throws {
        let stub = StubExtractor(returning: [[1, 0, 0], [0, 1, 0]])
        let pcm = [Int16](repeating: 1000, count: 320_000)   // 20s → 恰好两窗
        let e = try await VoiceprintEnrollment.embedding(for: pcm, using: stub)
        // (1,0,0)+(0,1,0) 归一化 = (0.7071, 0.7071, 0)
        XCTAssertEqual(e.count, 3)
        XCTAssertEqual(e[0], 0.70710678, accuracy: 1e-5)
        XCTAssertEqual(e[1], 0.70710678, accuracy: 1e-5)
        XCTAssertEqual(e[2], 0, accuracy: 1e-6)
        // 结果必须是单位向量 —— 聚类的 cosine 是纯点积,没归一化会整体偏移阈值
        let norm = e.reduce(0) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 1e-5)
    }

    // 每个窗都真的被送进了抽取器(而不是只送第一个窗)
    func testEveryWindowIsFedToExtractor() async throws {
        let stub = StubExtractor(returning: [[1, 0, 0], [1, 0, 0], [1, 0, 0]])
        let pcm = [Int16](repeating: 500, count: 400_000)     // 25s → 10s+10s+5s
        _ = try await VoiceprintEnrollment.embedding(for: pcm, using: stub)
        let counts = await stub.counts()
        XCTAssertEqual(counts, [160_000, 160_000, 80_000])
    }

    // 单窗输入:结果就是那一条(已归一化)向量本身
    func testSingleWindowPassesThroughNormalized() async throws {
        let stub = StubExtractor(returning: [[3, 4, 0]])
        let pcm = [Int16](repeating: 100, count: 160_000)
        let e = try await VoiceprintEnrollment.embedding(for: pcm, using: stub)
        XCTAssertEqual(e[0], 0.6, accuracy: 1e-5)
        XCTAssertEqual(e[1], 0.8, accuracy: 1e-5)
    }

    func testEmptyPCMThrows() async {
        let stub = StubExtractor(returning: [[1, 0, 0]])
        do {
            _ = try await VoiceprintEnrollment.embedding(for: [], using: stub)
            XCTFail("空样本应当抛错")
        } catch {
            XCTAssertEqual(error as? VoiceprintEnrollment.EnrollError, .empty)
        }
    }

    // 任一窗失败即整体失败:注册是一次性动作,宁可重录也不要悄悄存半份数据的弱档案
    func testExtractorFailurePropagates() async {
        let stub = StubExtractor(returning: [], failure: StubError())
        let pcm = [Int16](repeating: 100, count: 320_000)
        do {
            _ = try await VoiceprintEnrollment.embedding(for: pcm, using: stub)
            XCTFail("抽取失败应当抛出")
        } catch is StubError {
            // 期望
        } catch {
            XCTFail("抛错类型不对:\(error)")
        }
    }

    // 各窗维度不一致(模型中途换了)→ 明确报错,不做静默截断
    func testDimensionMismatchThrows() async {
        let stub = StubExtractor(returning: [[1, 0, 0], [1, 0]])
        let pcm = [Int16](repeating: 100, count: 320_000)
        do {
            _ = try await VoiceprintEnrollment.embedding(for: pcm, using: stub)
            XCTFail("维度不一致应当抛错")
        } catch {
            XCTAssertEqual(error as? VoiceprintEnrollment.EnrollError, .dimensionMismatch)
        }
    }

    // 各窗互相抵消成零向量 → 归一化不了,明确报错而非返回 NaN
    func testDegenerateAverageThrows() async {
        let stub = StubExtractor(returning: [[1, 0, 0], [-1, 0, 0]])
        let pcm = [Int16](repeating: 100, count: 320_000)
        do {
            _ = try await VoiceprintEnrollment.embedding(for: pcm, using: stub)
            XCTFail("零向量应当抛错")
        } catch {
            XCTAssertEqual(error as? VoiceprintEnrollment.EnrollError, .degenerate)
        }
    }
}

// MARK: - 录制时长闸门

final class VoiceprintRecorderGateTests: XCTestCase {
    // 闸门抽成纯静态函数就是为了不接麦克风也能测(录音器本身要真实 AVAudioEngine,不可单测)
    func testBelowMinimumIsNotSavable() {
        XCTAssertFalse(VoiceprintRecorder.canSave(seconds: 0))
        XCTAssertFalse(VoiceprintRecorder.canSave(seconds: 5))
        XCTAssertFalse(VoiceprintRecorder.canSave(seconds: 14.99))
    }

    func testAtOrAboveMinimumIsSavable() {
        XCTAssertTrue(VoiceprintRecorder.canSave(seconds: 15))
        XCTAssertTrue(VoiceprintRecorder.canSave(seconds: 20))
        XCTAssertTrue(VoiceprintRecorder.canSave(seconds: 45))
    }

    func testGateConstants() {
        XCTAssertEqual(VoiceprintRecorder.minimumSeconds, 15)
        // 建议时长必须 ≥ 硬下限,否则提示语会自相矛盾
        XCTAssertGreaterThanOrEqual(VoiceprintRecorder.recommendedSeconds,
                                    VoiceprintRecorder.minimumSeconds)
        XCTAssertGreaterThan(VoiceprintRecorder.maximumSeconds,
                             VoiceprintRecorder.recommendedSeconds)
    }

    // 建议时长(20s)必须能切出不止一窗,否则「读满 20 秒」仍会被 10s 窗口吃掉一半
    func testRecommendedDurationSpansMoreThanOneWindow() {
        let samples = Int(VoiceprintRecorder.recommendedSeconds * 16000)
        XCTAssertGreaterThan(VoiceprintEnrollment.windows(sampleCount: samples).count, 1)
    }
}

// MARK: - 录音器的非录音部分(档案读取/删除;录音本身要真麦克风,不可单测)

@MainActor
final class VoiceprintRecorderStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecorderTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    private func makeProfile(_ language: VoiceprintProfile.Language,
                             modelID: String? = "wespeaker_v2") -> VoiceprintProfile {
        VoiceprintProfile(language: language, embedding: [1, 0, 0],
                          recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
                          durationSeconds: 22, modelID: modelID)
    }

    // init 什么也不做(SwiftUI 每次 body 求值都会构造一遍),档案要 loadIfNeeded 才出现
    func testInitDoesNotLoadProfiles() throws {
        let store = try VoiceprintStore(directory: tempDir)
        try store.save(makeProfile(.chinese))
        let recorder = VoiceprintRecorder(store: store)
        XCTAssertTrue(recorder.profiles.isEmpty)
        recorder.loadIfNeeded()
        XCTAssertEqual(recorder.profiles.count, 1)
    }

    func testLoadIsIdempotent() throws {
        let store = try VoiceprintStore(directory: tempDir)
        try store.save(makeProfile(.chinese))
        let recorder = VoiceprintRecorder(store: store)
        recorder.loadIfNeeded()
        recorder.loadIfNeeded()
        XCTAssertEqual(recorder.profiles.count, 1)
    }

    func testProfileLookupByLanguage() throws {
        let store = try VoiceprintStore(directory: tempDir)
        try store.save(makeProfile(.chinese))
        let recorder = VoiceprintRecorder(store: store)
        recorder.loadIfNeeded()
        XCTAssertEqual(recorder.profile(for: .chinese)?.language, .chinese)
        XCTAssertNil(recorder.profile(for: .english))
    }

    // 删除后内存态与磁盘都要跟上(否则界面显示已删、重启又冒出来)
    func testDeleteRemovesProfileAndPersists() throws {
        let store = try VoiceprintStore(directory: tempDir)
        try store.save(makeProfile(.chinese))
        try store.save(makeProfile(.english))
        let recorder = VoiceprintRecorder(store: store)
        recorder.loadIfNeeded()
        recorder.delete(language: .chinese)
        XCTAssertNil(recorder.profile(for: .chinese))
        XCTAssertNotNil(recorder.profile(for: .english))
        let reopened = try VoiceprintStore(directory: tempDir)
        XCTAssertEqual(reopened.profiles.count, 1)
    }

    // 换了模型的旧档案要被标出来提示重录
    func testStaleProfileIsFlagged() throws {
        let store = try VoiceprintStore(directory: tempDir)
        let recorder = VoiceprintRecorder(store: store)
        XCTAssertTrue(recorder.isStale(makeProfile(.chinese, modelID: "campplus_v1")))
        XCTAssertFalse(recorder.isStale(makeProfile(.chinese, modelID: "wespeaker_v2")))
        XCTAssertFalse(recorder.isStale(makeProfile(.chinese, modelID: nil)))
    }

    func testInitialPhaseIsIdleAndNotBusy() throws {
        let recorder = VoiceprintRecorder(store: try VoiceprintStore(directory: tempDir))
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertFalse(recorder.isBusy)
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.canSaveNow)   // elapsed = 0
    }

    // 提示条能清掉,不会一直挂在设置页上
    func testClearMessageResetsToIdle() throws {
        let store = try VoiceprintStore(directory: tempDir)
        try store.save(makeProfile(.chinese))
        let recorder = VoiceprintRecorder(store: store)
        recorder.loadIfNeeded()
        recorder.delete(language: .chinese)
        guard case .message = recorder.phase else {
            return XCTFail("删除后应给出提示,实际 \(recorder.phase)")
        }
        recorder.clearMessage()
        XCTAssertEqual(recorder.phase, .idle)
    }
}

// MARK: - 录音状态机(ingest 零 AVFoundation,纯状态数学,可直接喂样本)

@MainActor
final class VoiceprintRecorderIngestTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("IngestTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    private func makeRecorder() throws -> VoiceprintRecorder {
        let recorder = VoiceprintRecorder(store: try VoiceprintStore(directory: tempDir))
        recorder.loadIfNeeded()
        return recorder
    }

    /// 直接把录音器摆进 .recording —— 不碰麦克风,只测 ingest 之后的状态迁移。
    private func armed(_ recorder: VoiceprintRecorder) {
        recorder.beginForTesting(language: .chinese)
    }

    private func chunk(seconds: Double, amplitude: Int16 = 8000) -> [Int16] {
        [Int16](repeating: amplitude, count: Int(seconds * 16000))
    }

    // 不在 .recording 时来的样本一律丢弃(preparing 的尾包、停采集后的残包)
    func testIngestIgnoredWhenNotRecording() throws {
        let recorder = try makeRecorder()
        recorder.ingest(chunk(seconds: 5))
        XCTAssertEqual(recorder.elapsed, 0)
        XCTAssertEqual(recorder.phase, .idle)
    }

    // elapsed = 累计样本数 / 16000,跨多批累加
    func testElapsedAccumulatesAcrossChunks() throws {
        let recorder = try makeRecorder()
        armed(recorder)
        recorder.ingest(chunk(seconds: 3))
        XCTAssertEqual(recorder.elapsed, 3, accuracy: 1e-9)
        recorder.ingest(chunk(seconds: 4.5))
        XCTAssertEqual(recorder.elapsed, 7.5, accuracy: 1e-9)
    }

    // 闸门跟着 elapsed 走:15s 之前存不了,之后能存
    func testCanSaveNowFlipsAtMinimum() throws {
        let recorder = try makeRecorder()
        armed(recorder)
        recorder.ingest(chunk(seconds: 14))
        XCTAssertFalse(recorder.canSaveNow)
        recorder.ingest(chunk(seconds: 1))
        XCTAssertTrue(recorder.canSaveNow)
    }

    func testLevelTracksPeakAmplitude() throws {
        let recorder = try makeRecorder()
        armed(recorder)
        recorder.ingest(chunk(seconds: 0.1, amplitude: 32767))
        XCTAssertEqual(recorder.level, 1.0, accuracy: 0.001)
        // 快起慢落:安静的一批不会把电平直接砸到 0
        recorder.ingest(chunk(seconds: 0.1, amplitude: 0))
        XCTAssertEqual(recorder.level, 0.8, accuracy: 0.001)
        XCTAssertGreaterThan(recorder.level, 0)
    }

    // MARK: 120s 上限

    // 录满上限:停下、进等确认态 —— **不能**自动保存
    func testReachingLimitStopsAndAwaitsConfirmation() throws {
        let recorder = try makeRecorder()
        armed(recorder)
        recorder.ingest(chunk(seconds: VoiceprintRecorder.maximumSeconds))
        XCTAssertTrue(recorder.isAwaitingLimitConfirmation)
        XCTAssertFalse(recorder.isRecording)
        // 关键回归:上限防的就是「点了录制然后走开」,自动存档等于做了它要防的事
        XCTAssertNotEqual(recorder.phase, .processing)
        XCTAssertTrue(recorder.profiles.isEmpty, "录满上限绝不能自动写档案")
    }

    // 样本要留着,用户确认后还能存 —— 否则等确认态是个死胡同
    func testSamplesSurviveLimitSoUserCanStillSave() throws {
        let recorder = try makeRecorder()
        armed(recorder)
        recorder.ingest(chunk(seconds: VoiceprintRecorder.maximumSeconds))
        XCTAssertGreaterThanOrEqual(recorder.elapsed, VoiceprintRecorder.maximumSeconds)
        XCTAssertTrue(recorder.canSaveNow)
    }

    // 等确认态不算 busy:保存和重录两个出路都得能点
    func testLimitReachedIsNotBusy() throws {
        let recorder = try makeRecorder()
        armed(recorder)
        recorder.ingest(chunk(seconds: VoiceprintRecorder.maximumSeconds))
        XCTAssertFalse(recorder.isBusy)
    }

    // 重录 = cancel:样本清空,回到 idle,什么也没存
    func testCancelAfterLimitDiscardsSamples() throws {
        let recorder = try makeRecorder()
        armed(recorder)
        recorder.ingest(chunk(seconds: VoiceprintRecorder.maximumSeconds))
        recorder.cancel()
        XCTAssertEqual(recorder.phase, .idle)
        XCTAssertEqual(recorder.elapsed, 0)
        XCTAssertTrue(recorder.profiles.isEmpty)
    }

    // 到上限后又来的残包不再累加(采集已停,phase 已不是 .recording)
    func testIngestAfterLimitIsIgnored() throws {
        let recorder = try makeRecorder()
        armed(recorder)
        recorder.ingest(chunk(seconds: VoiceprintRecorder.maximumSeconds))
        let elapsedAtLimit = recorder.elapsed
        recorder.ingest(chunk(seconds: 5))
        XCTAssertEqual(recorder.elapsed, elapsedAtLimit, accuracy: 1e-9)
    }

    // 不足 15s 就停 → 拒绝保存并丢弃样本,不留半截数据
    func testFinishBelowMinimumRejectsAndDiscards() throws {
        let recorder = try makeRecorder()
        armed(recorder)
        recorder.ingest(chunk(seconds: 8))
        recorder.finishAndSave()
        guard case .failure = recorder.phase else {
            return XCTFail("不足 15 秒应当拒绝,实际 \(recorder.phase)")
        }
        XCTAssertEqual(recorder.elapsed, 0)
        XCTAssertTrue(recorder.profiles.isEmpty)
    }
}

/// 朗读语料必须够长 —— 读完不到建议时长的话,提示文本本身就是在骗用户。
final class VoiceprintPromptTests: XCTestCase {
    func testChinesePromptIsLongEnough() {
        let text = VoiceprintPrompt.text(for: .chinese)
        // 中文正常语速约 4–5 字/秒,读满 20s 需 ~80–100 字
        XCTAssertGreaterThan(text.count, 100)
    }

    func testEnglishPromptIsLongEnough() {
        let words = VoiceprintPrompt.text(for: .english).split(separator: " ").count
        // 英文约 150 词/分 = 2.5 词/秒,读满 20s 需 ~50 词
        XCTAssertGreaterThan(words, 55)
    }

    // 不能有换行符残留(内联时用了续行反斜杠,写错会多出硬换行)
    func testPromptsAreSingleParagraph() {
        for language in VoiceprintProfile.Language.allCases {
            XCTAssertFalse(VoiceprintPrompt.text(for: language).contains("\n"),
                           "\(language) 的朗读文本混进了换行")
        }
    }
}
