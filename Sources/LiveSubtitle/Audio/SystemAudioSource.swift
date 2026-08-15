import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// 用 ScreenCaptureKit 采集系统输出音频(纯系统声,不含麦克风)。
final class SystemAudioSource: NSObject, AudioSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let track: Track = .system
    /// 采集启动失败(多为未授权『屏幕录制』)时上报;由 CaptionEngine 接到 UI。
    var onError: (@Sendable (String) -> Void)?
    private let converter = FormatConverter()
    private var stream: SCStream?
    private var continuation: AsyncStream<AudioFrame>.Continuation?
    private var startTask: Task<Void, Never>?
    private var stopped = false   // stop 已调用;start 在异步就绪后据此自拆,避免孤儿 SCStream

    func frames() -> AsyncStream<AudioFrame> {
        AsyncStream(bufferingPolicy: .bufferingNewest(32)) { cont in
            self.continuation = cont
            self.startTask = Task { await self.start() }
        }
    }

    private func start() async {
        do {
            let content = try await SCShareableContent.current
            if stopped { continuation?.finish(); return }   // 解析期间已 stop → 不再建流
            guard let display = content.displays.first else {
                onError?("未找到可采集的显示器"); continuation?.finish(); return
            }
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
            if stopped {                       // startCapture 期间已 stop → 立即拆掉,别留孤儿流
                try? await s.stopCapture()
                continuation?.finish(); return
            }
            stream = s
        } catch {
            onError?("系统音频采集失败:\(error.localizedDescription) — 请在 系统设置→隐私与安全性→屏幕录制 授权 LiveSubtitle")
            continuation?.finish()
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }
        guard let samples = try? converter.convert(pcm) else { return }
        continuation?.yield(AudioFrame(pcm: samples, track: .system, hostTime: mach_absolute_time()))
    }

    func stop() async {
        stopped = true
        startTask?.cancel()
        _ = await startTask?.value          // 等在途 start 结束:它要么自拆、要么已把 stream 设好
        try? await stream?.stopCapture()    // 兜底停掉已建好的流
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
