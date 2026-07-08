import Foundation
import Speech
import AVFoundation

struct TranscriptEvent: Sendable { let text: String; let isFinal: Bool }

/// 单轨英文流式识别。喂 AudioFrame,吐 TranscriptEvent(中间态/终句)。
actor TranscriptionPipeline {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var inputCont: AsyncStream<AnalyzerInput>.Continuation?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 16000, channels: 1, interleaved: true)!

    init() {
        transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange])
        analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    /// 确保 en-US 模型已安装(headless 可下)。
    func ensureModel() async throws {
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }
    }

    /// 启动:返回结果事件流;内部起分析 Task。
    func start() async throws -> AsyncStream<TranscriptEvent> {
        let (inStream, inCont) = AsyncStream<AnalyzerInput>.makeStream()
        inputCont = inCont
        try await analyzer.start(inputSequence: inStream)
        return AsyncStream { cont in
            Task {
                do {
                    for try await r in transcriber.results {
                        cont.yield(TranscriptEvent(text: String(r.text.characters), isFinal: r.isFinal))
                    }
                } catch { }
                cont.finish()
            }
        }
    }

    /// 喂入一帧(已是 16k/Int16/mono 样本)。
    func feed(_ frame: AudioFrame) {
        guard let buf = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                         frameCapacity: AVAudioFrameCount(frame.pcm.count)) else { return }
        buf.frameLength = AVAudioFrameCount(frame.pcm.count)
        frame.pcm.withUnsafeBufferPointer { src in
            buf.int16ChannelData![0].update(from: src.baseAddress!, count: frame.pcm.count)
        }
        inputCont?.yield(AnalyzerInput(buffer: buf))
    }

    func stop() async {
        inputCont?.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
    }
}
