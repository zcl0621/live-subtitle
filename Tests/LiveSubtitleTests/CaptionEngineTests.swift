import XCTest
@testable import LiveSubtitle

/// 不产帧的假轨,只用来验证 track 标签贯通 store。
private final class FakeSource: AudioSource, @unchecked Sendable {
    let track: Track
    var onError: (@Sendable (String) -> Void)?
    init(_ t: Track) { track = t }
    func frames() -> AsyncStream<AudioFrame> { AsyncStream { $0.finish() } }
    func stop() async {}
}

@MainActor
final class CaptionEngineTests: XCTestCase {
    private func freshSuite() -> UserDefaults {
        UserDefaults(suiteName: "test.ls.\(UUID().uuidString)")!
    }

    /// 语种在 init 定格:SpeechTranscriber 此刻按它构建,之后改设置只影响下一场。
    /// 同时验证引擎把"本场是什么语种"这个事实写回 store,供视图门控译文栏。
    func testEngineSnapshotsMeetingLanguageAtInit() {
        let store = SubtitleStore(defaults: freshSuite())
        store.meetingLanguage = .chinese
        let engine = CaptionEngine(store: store, tracks: [])
        XCTAssertEqual(engine.meetingLanguage, .chinese)
        XCTAssertEqual(store.sessionLanguage, .chinese)
        store.meetingLanguage = .english      // 改的是【下一场】
        XCTAssertEqual(engine.meetingLanguage, .chinese)
        XCTAssertEqual(store.sessionLanguage, .chinese)
    }

    func testStoreHandlesInterleavedSpeakersViaStageFlush() {
        let store = SubtitleStore()
        store.stageVolatile(track: .system, text: "hello")
        store.stageVolatile(track: .mic, text: "hi")
        store.flushVolatile()
        let id = store.commitFinal(track: .system, text: "hello there")
        store.attachTranslation(id: id, zh: "你好")
        XCTAssertEqual(store.lines.filter { $0.speaker.track == .mic }.count, 1)
        let other = store.lines.first { $0.speaker.track == .system && $0.isFinal }
        XCTAssertEqual(other?.translated, "你好")
    }

    func testFakeSourceConformsAndSpeakerTagged() {
        XCTAssertEqual(FakeSource(.mic).track, .mic)
        XCTAssertEqual(FakeSource(.system).track, .system)
    }
}
