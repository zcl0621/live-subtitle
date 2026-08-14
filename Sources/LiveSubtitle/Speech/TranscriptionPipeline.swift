import Foundation
import Speech
import AVFoundation

struct TranscriptEvent: Sendable {
    let text: String
    let isFinal: Bool
    /// 终句在 analyzer 音频时间轴上的秒区间(声纹归属切片用);中间态为 nil。
    let audioRange: Range<Double>?

    init(text: String, isFinal: Bool, audioRange: Range<Double>? = nil) {
        self.text = text; self.isFinal = isFinal; self.audioRange = audioRange
    }
}

/// 单轨流式识别(语种由 init 的 locale 决定,构建后不可变)。喂 AudioFrame,吐 TranscriptEvent(中间态/终句)。
actor TranscriptionPipeline {
    private let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private var inputCont: AsyncStream<AnalyzerInput>.Continuation?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                             sampleRate: 16000, channels: 1, interleaved: true)!
    /// 声纹切片用环形缓冲(60s @16k)。只在 feed 里、成功喂给 analyzer 的同一批样本
    /// 才 append —— 缓冲计数与 analyzer 时间轴严格同源,r.range 的秒数才能换算成样本序号。
    private let ringBuffer = AudioRingBuffer(capacity: 16000 * 60)

    /// locale 决定识别语种;SpeechTranscriber 一经构建就锁死语种,所以会议中途换不了。
    init(locale: Locale) {
        transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange])
        analyzer = SpeechAnalyzer(modules: [transcriber])
    }

    /// 确保该语种模型已安装(headless 可下;P1 验过 en-US,P7 验过 zh-CN)。
    func ensureModel() async throws {
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await req.downloadAndInstall()
        }
    }

    /// 启动:返回结果事件流;内部起分析 Task。
    /// onError:识别流中途抛错时上报(否则字幕会静默冻结,用户无从察觉)。
    func start(onError: (@Sendable (String) -> Void)? = nil) async throws -> AsyncStream<TranscriptEvent> {
        let (inStream, inCont) = AsyncStream<AnalyzerInput>.makeStream()
        inputCont = inCont
        try await analyzer.start(inputSequence: inStream)
        return AsyncStream { cont in
            Task {
                do {
                    for try await r in transcriber.results {
                        // 终句才带 audioRange(P6a/P7 验证:r.range 非可选,秒数对齐 analyzer 时间轴)
                        var audioRange: Range<Double>?
                        if r.isFinal {
                            let s = r.range.start.seconds
                            let e = r.range.end.seconds
                            if s.isFinite, e.isFinite, e > s { audioRange = s..<e }
                        }
                        cont.yield(TranscriptEvent(text: String(r.text.characters),
                                                   isFinal: r.isFinal, audioRange: audioRange))
                    }
                } catch {
                    onError?("识别中断:\(error.localizedDescription) — 请停止后重开字幕")
                }
                cont.finish()
            }
        }
    }

    /// 喂入一帧(已是 16k/Int16/mono 样本)。
    func feed(_ frame: AudioFrame) {
        guard let inputCont,
              let buf = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                         frameCapacity: AVAudioFrameCount(frame.pcm.count)) else { return }
        buf.frameLength = AVAudioFrameCount(frame.pcm.count)
        frame.pcm.withUnsafeBufferPointer { src in
            buf.int16ChannelData![0].update(from: src.baseAddress!, count: frame.pcm.count)
        }
        ringBuffer.append(frame.pcm)   // 与下面 yield 同一批样本,时间基不漂
        inputCont.yield(AnalyzerInput(buffer: buf))
    }

    /// 按终句秒区间取原始样本(声纹切片)。已被环形覆盖 / 尚未写入返回 nil。
    func sliceAudio(seconds: Range<Double>) -> [Int16]? {
        ringBuffer.slice(seconds: seconds, sampleRate: 16000)
    }

    func stop() async {
        inputCont?.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
    }
}
