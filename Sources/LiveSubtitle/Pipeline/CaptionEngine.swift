import Foundation

@MainActor
final class CaptionEngine {
    let store: SubtitleStore
    private struct TrackBundle { let source: AudioSource; let pipeline: TranscriptionPipeline; let translator: TranslationService }
    private var tracks: [TrackBundle]
    private var tasks: [Task<Void, Never>] = []
    private var flushTask: Task<Void, Never>?
    private var volatileTranslateTask: Task<Void, Never>?
    private var lastVolatileSource: [Track: String] = [:]   // 每轨上次已送翻译的中间态,去重
    private var volatileInFlight: Set<Track> = []           // 每轨是否有中间态翻译在途,防叠
    private var stopped = false                               // stop 后为 true,阻止旧 consume 继续写共享 store
    /// 进程级共享声纹抽取器(持具体类型:prepare 不在 protocol 上,attributor 拿协议接缝)。
    /// 共享而非 per-engine:模型加载 + ~3s CoreML 预热整个进程只付一次(prepare 幂等);
    /// 丢弃的 engine 不会被慢速首次下载的 prepare 钩住不释放;快速 stop/start 也不会
    /// 并发跑两个 downloadIfNeeded 打同一个模型目录。
    static let sharedExtractor = FluidAudioExtractor()
    /// 非 private:测试据此核对设置页的阈值确实定格进了本场。
    let attributor: SpeakerAttributor
    /// 声纹模型就绪后才为终句起归属 Task;未就绪时省掉每句白付的切片 + Float 转换 + 两次 actor 跳跃。
    private var attributionReady = false

    /// 本场会议语种,init 时从 store 定格。SpeechTranscriber 在此刻按它构建,
    /// 之后再改设置也不影响本场(UI 侧运行中把 Picker 置灰,语义一致)。
    let meetingLanguage: MeetingLanguage

    /// 默认双轨:对方(系统音)+ 我(麦克风)。测试可注入自定义轨。
    init(store: SubtitleStore, tracks: [(AudioSource, TranscriptionPipeline)]? = nil) {
        self.store = store
        let language = store.meetingLanguage
        self.meetingLanguage = language
        // 开一场:把"本场是什么语种"这个事实写回 store(视图据此决定显不显示译文栏,
        // 否则视图读实时设置、引擎按快照跑,两份真相只靠 Picker 置灰来对齐),
        // 同时换一枚 sessionID —— 上屏的行盖本场的章,导出才切得出"这一场"。
        store.beginSession(language: language)
        let built = tracks ?? [
            (SystemAudioSource(), TranscriptionPipeline(locale: language.locale)),
            (MicSource(), TranscriptionPipeline(locale: language.locale)),
        ]
        self.tracks = built.map { TrackBundle(source: $0.0, pipeline: $0.1, translator: TranslationService()) }
        // 「我」的声纹档案读不出(首次运行/损坏)就当没有档案:仍能聚类,只是没人判成 .me
        // 按 modelID 过滤:盖了别的模型的章 = 向量空间不通用,宁可当没有档案
        // (判定规则与 nil 遗留档案的处理见 VoiceprintProfile.isCompatible)。
        let meProfiles = (try? VoiceprintStore())?
            .meEmbeddings(modelID: FluidAudioExtractor.modelID) ?? []
        // 阈值与语种一样在 init 定格:clusterer 在此刻按它构建,中途改设置不影响本场
        // (设置页运行中把滑杆置灰,语义一致)。区间与 θ_me > θ_cluster 由 store 守。
        self.attributor = SpeakerAttributor(extractor: Self.sharedExtractor,
                                            meProfiles: meProfiles,
                                            thresholdMe: Float(store.thresholdMe),
                                            thresholdCluster: Float(store.thresholdCluster))
    }

    func start(onError: @escaping @MainActor (String) -> Void) {
        // 声纹模型预热:首次要下载(~13MB)+ ~3s CoreML 预热,放后台跑,
        // 字幕主链路不等它;失败非致命 —— 上报一次,说话人保持 unresolved。
        // [weak self]:prepare 慢(首次下载可达分钟级)时不钩住已丢弃的 engine。
        tasks.append(Task { @MainActor [weak self] in
            do {
                try await Self.sharedExtractor.prepare()
                self?.attributionReady = true
            } catch {
                onError("声纹模型准备失败:\(error.localizedDescription) — 本场说话人标注不可用,字幕不受影响")
            }
        })
        // 每轨独立翻译服务,逐一暖机;中文包未装只报一次(失败即停,不刷屏)。
        // 中文会议整条翻译链路都不跑 —— 连暖机都不调,不白占 Translation 会话与内存,
        // 也不会因用户没装中文语言包而弹一条与本场无关的报错。
        if meetingLanguage.needsTranslation {
            tasks.append(Task {
                for track in tracks {
                    do { try await track.translator.warmUp() }
                    catch { onError("请在 系统设置→通用→语言与地区→翻译语言 安装 中文(简体)"); break }
                }
            })
        }
        // 每条轨:接 onError → ensureModel → start → 消费 + 喂
        for track in tracks {
            track.source.onError = { msg in Task { @MainActor in onError(msg) } }
            tasks.append(Task {
                do {
                    try await track.pipeline.ensureModel()
                    // 识别流中途抛错 → 上报,避免字幕静默冻结
                    let events = try await track.pipeline.start(onError: { msg in
                        Task { @MainActor in onError(msg) }
                    })
                    let consume = Task { @MainActor in
                        for await e in events {
                            if stopped { break }   // stop 后不再写共享 store(防旧会话污染快速重启的新会话)
                            if e.isFinal {
                                let id = store.commitFinal(track: track.source.track, text: e.text)
                                lastVolatileSource[track.source.track] = nil   // 定稿后清去重,下句同短语也能边说边译
                                // 声纹归属:异步判定后按 id 回填,不阻塞翻译/上屏。
                                // 模型未就绪不起 Task(免得每句白付切片 + Float 转换 + 两次
                                // actor 跳跃只为吃个 notPrepared);就绪前的终句保持
                                // .unresolved —— 事后补判定留作后续 polish。
                                if attributionReady, let range = e.audioRange {
                                    let pipeline = track.pipeline
                                    let tr = track.source.track
                                    Task { @MainActor [attributor, store] in
                                        let pcm = await pipeline.sliceAudio(seconds: range)
                                        let sp = await attributor.attribute(track: tr, range: range, pcm: pcm)
                                        store.attachSpeaker(id: id, speaker: sp)
                                    }
                                }
                                // 中文会议不翻译;英文会议下原文模式也不触发(省资源,对齐 PRD)
                                if meetingLanguage.needsTranslation, store.displayMode.showsTranslated {
                                    Task { @MainActor in
                                        if let zh = await track.translator.translate(e.text) {
                                            store.attachTranslation(id: id, zh: zh)
                                        } else {
                                            store.markTranslationFailed(id: id)   // 失败打标,UI 回退显原文
                                        }
                                    }
                                }
                            } else {
                                store.stageVolatile(track: track.source.track, text: e.text)
                            }
                        }
                    }
                    for await frame in track.source.frames() {
                        await track.pipeline.feed(frame)
                    }
                    await consume.value
                } catch is CancellationError {
                    // 用户主动停止,不当作错误上报
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
        // 中文会议压根不起边说边译的轮询 Task,不让它空转。
        if meetingLanguage.needsTranslation { startVolatileTranslateLoop() }
    }

    /// 边说边译:每 ~450ms 把当前中间态送翻译(受 translateVolatile + displayMode 门控;
    /// 每轨内容未变则跳过、在途则不叠;译文经 attachVolatileTranslation 守卫回填)。
    /// 只在需要翻译的会议里启动 —— 调用方负责门控。
    private func startVolatileTranslateLoop() {
        volatileTranslateTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(450))
                guard store.translateVolatile, store.displayMode.showsTranslated else { continue }
                for track in tracks {
                    let tr = track.source.track
                    guard !volatileInFlight.contains(tr),
                          let text = store.currentVolatileText(track: tr),
                          !text.isEmpty, text != lastVolatileSource[tr] else { continue }
                    lastVolatileSource[tr] = text
                    volatileInFlight.insert(tr)
                    let translator = track.translator
                    Task { @MainActor in
                        let zh = await translator.translate(text)
                        volatileInFlight.remove(tr)
                        if let zh { store.attachVolatileTranslation(track: tr, sourceText: text, zh: zh) }
                    }
                }
            }
        }
    }

    func stop() {
        stopped = true
        flushTask?.cancel(); flushTask = nil
        volatileTranslateTask?.cancel(); volatileTranslateTask = nil
        tasks.forEach { $0.cancel() }; tasks = []
        let tracks = self.tracks
        // 先并发停所有采集源(麦克风立即停录),再并发收尾所有 pipeline
        //
        // **这里不调 `attributor.reset()`**,尽管"别把这场的说话人带进下一场"确实是要守的。
        // 守它的是生命周期而不是这一句:attributor 是 per-engine 的 let,下一场由
        // LiveSubtitleApp 新建一个 CaptionEngine,连着新的 SpeakerClusterer(centroids 空、
        // 簇号从 0 重新编),旧的随 `engine = nil` 一起丢。
        //
        // 而调它反倒有害:上面 101 行起的归属 Task 不进 `tasks`、不被取消,它们第一跳
        // `pipeline.sliceAudio` 会排在下面 `pipeline.stop()` 后面 —— 那一句要 await
        // `finalizeAndFinishThroughEndOfInput()`,可达数百 ms。等切片回来时 reset 早已落地,
        // 判定就在一个空 clusterer 上跑,最后一句必然被标成新簇「说话人 1」。
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
