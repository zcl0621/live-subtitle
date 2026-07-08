import Foundation

@MainActor
final class CaptionEngine {
    let store: SubtitleStore
    private let source = SystemAudioSource()
    private let pipeline = TranscriptionPipeline()
    private let translator = TranslationService()
    private var tasks: [Task<Void, Never>] = []

    init(store: SubtitleStore) { self.store = store }

    /// 启动整条链路。授权/装包错误通过 onError 回调上报。
    func start(onError: @escaping @MainActor (String) -> Void) {
        // 采集侧(SCStream 队列/后台 Task)报错 → 跳回主线程上报 UI。
        source.onError = { msg in Task { @MainActor in onError(msg) } }
        tasks.append(Task {
            do {
                try await pipeline.ensureModel()
                do { try await translator.warmUp() }
                catch { onError("请在 系统设置→通用→语言与地区→翻译语言 安装 中文(简体)") }

                let events = try await pipeline.start()
                // 消费识别结果 → 写 store,终句触发翻译
                let consume = Task { @MainActor in
                    for await e in events {
                        if e.isFinal {
                            let id = store.commitFinal(speaker: .other, text: e.text)
                            Task { @MainActor in
                                if let zh = await translator.translate(e.text) {
                                    store.attachTranslation(id: id, zh: zh)
                                }
                            }
                        } else {
                            store.upsertVolatile(speaker: .other, text: e.text)
                        }
                    }
                }
                // 采集 → 喂 pipeline
                for await frame in source.frames() {
                    await pipeline.feed(frame)
                }
                await consume.value
            } catch {
                onError("启动失败:\(error.localizedDescription)(检查屏幕录制授权)")
            }
        })
    }

    func stop() {
        tasks.forEach { $0.cancel() }; tasks = []
        Task { await source.stop(); await pipeline.stop() }
    }
}
