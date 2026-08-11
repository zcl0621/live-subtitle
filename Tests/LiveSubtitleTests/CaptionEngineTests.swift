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
