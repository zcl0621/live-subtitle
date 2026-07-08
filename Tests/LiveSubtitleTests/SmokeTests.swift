import XCTest
@testable import LiveSubtitle

final class SmokeTests: XCTestCase {
    func testScaffold() { XCTAssertEqual(Scaffold.ping(), "LiveSubtitle") }
}
