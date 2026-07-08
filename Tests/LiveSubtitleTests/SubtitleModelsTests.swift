import XCTest
@testable import LiveSubtitle

final class SubtitleModelsTests: XCTestCase {
    func testSubtitleLineDefaults() {
        let line = SubtitleLine(speaker: .other, original: "hello")
        XCTAssertEqual(line.speaker, .other)
        XCTAssertEqual(line.original, "hello")
        XCTAssertNil(line.translated)
        XCTAssertFalse(line.isFinal)
    }

    func testAudioFrameIsSendableValue() {
        let f = AudioFrame(pcm: [1, 2, 3], speaker: .other, hostTime: 42)
        XCTAssertEqual(f.pcm.count, 3)
        XCTAssertEqual(f.speaker, .other)
        XCTAssertEqual(f.hostTime, 42)
    }
}
