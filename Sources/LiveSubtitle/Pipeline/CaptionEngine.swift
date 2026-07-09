import Foundation

@MainActor
final class CaptionEngine {
    let store: SubtitleStore
    private struct Track { let source: AudioSource; let pipeline: TranscriptionPipeline; let translator: TranslationService }
    private var tracks: [Track]
    private var tasks: [Task<Void, Never>] = []
    private var flushTask: Task<Void, Never>?

    /// 默认双轨:对方(系统音)+ 我(麦克风)。测试可注入自定义轨。
    init(store: SubtitleStore, tracks: [(AudioSource, TranscriptionPipeline)]? = nil) {
        self.store = store
        let built = tracks ?? [
            (SystemAudioSource(), TranscriptionPipeline()),
            (MicSource(), TranscriptionPipeline()),
        ]
        self.tracks = built.map { Track(source: $0.0, pipeline: $0.1, translator: TranslationService()) }
    }

    func start(onError: @escaping @MainActor (String) -> Void) {
        // 每轨独立翻译服务,逐一暖机;中文包未装只报一次(失败即停,不刷屏)
        tasks.append(Task {
            for track in tracks {
                do { try await track.translator.warmUp() }
                catch { onError("请在 系统设置→通用→语言与地区→翻译语言 安装 中文(简体)"); break }
            }
        })
        // 每条轨:接 onError → ensureModel → start → 消费 + 喂
        for track in tracks {
            track.source.onError = { msg in Task { @MainActor in onError(msg) } }
            tasks.append(Task {
                do {
                    try await track.pipeline.ensureModel()
                    let events = try await track.pipeline.start()
                    let consume = Task { @MainActor in
                        for await e in events {
                            if e.isFinal {
                                let id = store.commitFinal(speaker: track.source.speaker, text: e.text)
                                Task { @MainActor in
                                    if let zh = await track.translator.translate(e.text) {
                                        store.attachTranslation(id: id, zh: zh)
                                    }
                                }
                            } else {
                                store.stageVolatile(speaker: track.source.speaker, text: e.text)
                            }
                        }
                    }
                    for await frame in track.source.frames() {
                        await track.pipeline.feed(frame)
                    }
                    await consume.value
                } catch {
                    onError("启动失败:\(error.localizedDescription)")
                }
            })
        }
        // 节流:每 120ms 把暂存的 volatile 一次性上屏
        flushTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                store.flushVolatile()
            }
        }
    }

    func stop() {
        flushTask?.cancel(); flushTask = nil
        tasks.forEach { $0.cancel() }; tasks = []
        let tracks = self.tracks
        // 先并发停所有采集源(麦克风立即停录),再并发收尾所有 pipeline
        Task {
            await withTaskGroup(of: Void.self) { g in
                for t in tracks { g.addTask { await t.source.stop() } }
            }
            await withTaskGroup(of: Void.self) { g in
                for t in tracks { g.addTask { await t.pipeline.stop() } }
            }
        }
    }
}
