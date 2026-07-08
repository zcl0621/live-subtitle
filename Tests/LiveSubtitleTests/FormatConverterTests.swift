import XCTest
import AVFoundation
@testable import LiveSubtitle

final class FormatConverterTests: XCTestCase {
    /// 造一个 48kHz / Float32 / 2ch、时长 0.5s 的正弦 buffer
    private func makeSource(seconds: Double) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000,
                                channels: 2, interleaved: false)!
        let frames = AVAudioFrameCount(48000 * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        for ch in 0..<2 {
            let p = buf.floatChannelData![ch]
            for i in 0..<Int(frames) { p[i] = sin(Float(i) * 0.05) * 0.5 }
        }
        return buf
    }

    func testConvertsToMono16kInt16WithExpectedCount() throws {
        let conv = FormatConverter()
        let out = try conv.convert(makeSource(seconds: 0.5))
        XCTAssertEqual(Double(out.count), 8000, accuracy: 64)   // 0.5s @16k ≈ 8000
        XCTAssertTrue(out.contains { $0 != 0 })                 // 非静音
    }

    func testTargetFormatIs16kInt16Mono() {
        let conv = FormatConverter()
        XCTAssertEqual(conv.targetFormat.sampleRate, 16000)
        XCTAssertEqual(conv.targetFormat.channelCount, 1)
        XCTAssertEqual(conv.targetFormat.commonFormat, .pcmFormatInt16)
    }
}
