import XCTest
@testable import LiveSubtitle

@MainActor
final class SubtitleStoreTests: XCTestCase {
    func testVolatileUpsertKeepsSingleLinePerSpeaker() {
        let s = SubtitleStore()
        s.upsertVolatile(speaker: .other, text: "Hey")
        s.upsertVolatile(speaker: .other, text: "Hey can")
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertEqual(s.lines[0].original, "Hey can")
        XCTAssertFalse(s.lines[0].isFinal)
    }

    func testCommitFinalPromotesSameIdAndReturnsIt() {
        let s = SubtitleStore()
        s.upsertVolatile(speaker: .other, text: "Hey there")
        let volatileId = s.lines[0].id
        let finalId = s.commitFinal(speaker: .other, text: "Hey there.")
        XCTAssertEqual(finalId, volatileId)
        XCTAssertEqual(s.lines.count, 1)
        XCTAssertTrue(s.lines[0].isFinal)
        XCTAssertEqual(s.lines[0].original, "Hey there.")
    }

    func testNextVolatileStartsNewLineAfterFinal() {
        let s = SubtitleStore()
        _ = s.commitFinal(speaker: .other, text: "One.")
        s.upsertVolatile(speaker: .other, text: "Two")
        XCTAssertEqual(s.lines.count, 2)
        XCTAssertFalse(s.lines[1].isFinal)
    }

    func testAttachTranslationById() {
        let s = SubtitleStore()
        let id = s.commitFinal(speaker: .other, text: "Hello.")
        s.attachTranslation(id: id, zh: "你好。")
        XCTAssertEqual(s.lines[0].translated, "你好。")
    }

    func testTwoSpeakersHaveIndependentVolatileLines() {
        let s = SubtitleStore()
        s.upsertVolatile(speaker: .other, text: "A")
        s.upsertVolatile(speaker: .me, text: "B")
        s.upsertVolatile(speaker: .other, text: "A2")
        XCTAssertEqual(s.lines.count, 2)
        XCTAssertEqual(s.lines.first { $0.speaker == .other }?.original, "A2")
        XCTAssertEqual(s.lines.first { $0.speaker == .me }?.original, "B")
    }
}
