import XCTest
@testable import LiveSubtitle

final class AudioRingBufferTests: XCTestCase {
    func testSliceWithinRetainedWindow() {
        let buf = AudioRingBuffer(capacity: 100)
        buf.append(Array(repeating: 1, count: 40))    // 序号 0..<40
        buf.append(Array(repeating: 2, count: 40))    // 序号 40..<80
        XCTAssertEqual(buf.slice(from: 40, count: 5), [2, 2, 2, 2, 2])
        XCTAssertEqual(buf.slice(from: 35, count: 10), [1,1,1,1,1, 2,2,2,2,2])
    }

    func testEvictedRangeReturnsNil() {
        let buf = AudioRingBuffer(capacity: 100)
        buf.append(Array(repeating: 1, count: 150))   // 0..<50 已被覆盖
        XCTAssertNil(buf.slice(from: 0, count: 10))
        XCTAssertNotNil(buf.slice(from: 60, count: 10))
    }

    func testFutureRangeReturnsNil() {
        let buf = AudioRingBuffer(capacity: 100)
        buf.append(Array(repeating: 1, count: 40))
        XCTAssertNil(buf.slice(from: 30, count: 50))  // 越过已写入末尾
    }

    func testWrapAroundBoundary() {
        let buf = AudioRingBuffer(capacity: 10)
        buf.append([1,2,3,4,5,6,7,8])
        buf.append([9,10,11,12])                       // 绕回,保留序号 2..<12
        XCTAssertEqual(buf.slice(from: 6, count: 6), [7,8,9,10,11,12])
    }

    func testTimeRangeConversion() {
        let buf = AudioRingBuffer(capacity: 16000 * 60)
        buf.append(Array(repeating: 7, count: 16000 * 3))
        // 1.0s..1.5s @16k → 序号 16000..<24000
        XCTAssertEqual(buf.slice(seconds: 1.0..<1.5, sampleRate: 16000)?.count, 8000)
    }
}
