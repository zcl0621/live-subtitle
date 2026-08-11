import XCTest
@testable import LiveSubtitle

final class SubtitleModelsTests: XCTestCase {
    func testSubtitleLineDefaults() {
        let line = SubtitleLine(speaker: .unresolved(.system), original: "hello")
        XCTAssertEqual(line.speaker.track, .system)
        XCTAssertEqual(line.original, "hello")
        XCTAssertNil(line.translated)
        XCTAssertFalse(line.isFinal)
    }

    func testAudioFrameIsSendableValue() {
        let f = AudioFrame(pcm: [1, 2, 3], track: .system, hostTime: 42)
        XCTAssertEqual(f.pcm.count, 3)
        XCTAssertEqual(f.track, .system)
        XCTAssertEqual(f.hostTime, 42)
    }
}
