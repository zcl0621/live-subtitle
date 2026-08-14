import XCTest
@testable import LiveSubtitle

final class VoiceprintExtractorTests: XCTestCase {

    // MARK: - PCMConvert.int16ToFloat

    func testInt16ToFloatZeroAndEmpty() {
        XCTAssertEqual(PCMConvert.int16ToFloat([]), [])
        XCTAssertEqual(PCMConvert.int16ToFloat([0, 0]), [0, 0])
    }

    func testInt16ToFloatExtremes() {
        // -32768 恰好映到 -1.0;+32767 映到略小于 1.0(Int16 不对称是格式固有的)
        let out = PCMConvert.int16ToFloat([Int16.min, Int16.max])
        XCTAssertEqual(out[0], -1.0)
        XCTAssertEqual(out[1], 32767.0 / 32768.0, accuracy: 1e-7)
        XCTAssertLessThan(out[1], 1.0)
    }

    func testInt16ToFloatMagnitudeNeverExceedsOne() {
        let samples: [Int16] = [.min, -16384, -1, 0, 1, 16384, .max]
        for f in PCMConvert.int16ToFloat(samples) {
            XCTAssertLessThanOrEqual(abs(f), 1.0)
        }
    }

    func testInt16ToFloatRoundTripMagnitude() {
        // 中间值:16384/32768 == 0.5 精确可表示
        XCTAssertEqual(PCMConvert.int16ToFloat([16384]), [0.5])
        XCTAssertEqual(PCMConvert.int16ToFloat([-16384]), [-0.5])
    }

    // MARK: - FluidAudioExtractor.l2Normalized

    private func l2norm(_ v: [Float]) -> Float {
        (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
    }

    func testL2NormalizedProducesUnitNorm() throws {
        // 模拟 P6a 实测:FluidAudio 原始输出 L2≈1.037,不是单位向量
        let raw: [Float] = [0.3, -0.7, 0.5, 0.2, -0.1, 0.9]
        let normalized = try XCTUnwrap(FluidAudioExtractor.l2Normalized(raw))
        XCTAssertEqual(l2norm(normalized), 1.0, accuracy: 1e-5)
    }

    func testL2NormalizedPreservesDirection() throws {
        let raw: [Float] = [3, 4]  // norm 5 → [0.6, 0.8]
        let normalized = try XCTUnwrap(FluidAudioExtractor.l2Normalized(raw))
        XCTAssertEqual(normalized[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(normalized[1], 0.8, accuracy: 1e-6)
    }

    func testL2NormalizedUnitVectorIsUnchanged() throws {
        let unit: [Float] = [0, 1, 0]
        let normalized = try XCTUnwrap(FluidAudioExtractor.l2Normalized(unit))
        XCTAssertEqual(normalized, unit)
    }

    func testL2NormalizedZeroVectorReturnsNil() {
        XCTAssertNil(FluidAudioExtractor.l2Normalized([0, 0, 0, 0]))
    }

    func testL2NormalizedEmptyReturnsNil() {
        XCTAssertNil(FluidAudioExtractor.l2Normalized([]))
    }

    func testL2NormalizedNonFiniteReturnsNil() {
        XCTAssertNil(FluidAudioExtractor.l2Normalized([1, .nan, 2]))
        XCTAssertNil(FluidAudioExtractor.l2Normalized([.infinity, 0]))
    }
}
