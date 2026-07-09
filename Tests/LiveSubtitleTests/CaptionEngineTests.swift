import XCTest
@testable import LiveSubtitle

/// 不产帧的假轨,只用来验证 speaker 标签贯通 store。
private final class FakeSource: AudioSource, @unchecked Sendable {
    let speaker: Speaker
    var onError: (@Sendable (String) -> Void)?
    init(_ s: Speaker) { speaker = s }
    func frames() -> AsyncStream<AudioFrame> { AsyncStream { $0.finish() } }
    func stop() async {}
}

@MainActor
final class CaptionEngineTests: XCTestCase {
    func testStoreHandlesInterleavedSpeakersViaStageFlush() {
        let store = SubtitleStore()
        store.stageVolatile(speaker: .other, text: "hello")
        store.stageVolatile(speaker: .me, text: "hi")
        store.flushVolatile()
        let id = store.commitFinal(speaker: .other, text: "hello there")
        store.attachTranslation(id: id, zh: "你好")
        XCTAssertEqual(store.lines.filter { $0.speaker == .me }.count, 1)
        let other = store.lines.first { $0.speaker == .other && $0.isFinal }
        XCTAssertEqual(other?.translated, "你好")
    }

    func testFakeSourceConformsAndSpeakerTagged() {
        XCTAssertEqual(FakeSource(.me).speaker, .me)
        XCTAssertEqual(FakeSource(.other).speaker, .other)
    }
}
