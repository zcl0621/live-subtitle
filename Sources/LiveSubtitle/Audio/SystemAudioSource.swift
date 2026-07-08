import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// 用 ScreenCaptureKit 采集系统输出音频(纯系统声,不含麦克风)。
final class SystemAudioSource: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let speaker: Speaker = .other
    private let converter = FormatConverter()
    private var stream: SCStream?
    private var continuation: AsyncStream<AudioFrame>.Continuation?

    func frames() -> AsyncStream<AudioFrame> {
        AsyncStream(bufferingPolicy: .bufferingNewest(32)) { cont in
            self.continuation = cont
            Task { await self.start() }
        }
    }

    private func start() async {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { continuation?.finish(); return }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.width = 2; config.height = 2
            let s = SCStream(filter: filter, configuration: config, delegate: self)
            try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "sysaudio"))
            try await s.startCapture()
            stream = s
        } catch {
            print("[SystemAudioSource] start failed: \(error) — 检查『屏幕录制』授权")
            continuation?.finish()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        guard let samples = try? converter.convert(pcm) else { return }
        continuation?.yield(AudioFrame(pcm: samples, speaker: .other, hostTime: mach_absolute_time()))
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
        continuation?.finish()
    }

    /// CMSampleBuffer → AVAudioPCMBuffer(Float32),供 FormatConverter 消费。
    private static func pcmBuffer(from sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return nil }
        var asbd = asbdPtr.pointee
        guard let fmt = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sb))
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames),
                                                                  into: buf.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return buf
    }
}
