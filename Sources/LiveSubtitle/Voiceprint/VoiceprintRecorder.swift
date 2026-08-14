import AVFoundation
import Foundation
import Observation

/// 设置页「我的声纹」的全部状态机:录音 → 抽向量 → 存档,外加档案列表与删除。
///
/// 采集路径与 `MicSource` 同构(AVAudioEngine tap → 取 0 声道 → FormatConverter →
/// 16k/单声道/Int16),**不开 VoiceProcessing** —— 理由见 MicSource 的注释。
/// 采集回调在音频线程,通过 `AsyncStream`(其 continuation 是 Sendable)把
/// 已转换好的 `[Int16]` 送回 MainActor 累积,全程不需要 @unchecked Sendable。
@MainActor
@Observable
final class VoiceprintRecorder {
    enum Phase: Equatable {
        case idle
        case preparing              // 正在要权限 / 起 engine
        case recording
        case processing             // 正在抽 embedding + 落盘
        case message(String)        // 成功提示
        case failure(String)        // 失败提示(可操作)
    }

    // 时长闸门是纯数字判定,与录音器的 MainActor 状态无关 —— 标 nonisolated,
    // 这样不接麦克风(录音器本身要真实 AVAudioEngine,不可单测)也能单测这条规则。

    /// 硬下限:低于此不给存。P6a 的档案样本都是 22–38s,短样本的向量不稳,
    /// 存一条弱档案比没有档案更糟 —— 它会让「我」时命中时不命中,用户还以为功能坏了。
    nonisolated static let minimumSeconds: Double = 15
    /// 建议时长。UI 到这里给「够了,可以停」的正反馈。
    nonisolated static let recommendedSeconds: Double = 20
    /// 录制上限,到点自动停:防止用户开着走开,内存无界增长(120s ≈ 3.8MB Int16)。
    nonisolated static let maximumSeconds: Double = 120

    /// 保存闸门。
    nonisolated static func canSave(seconds: Double) -> Bool { seconds >= minimumSeconds }

    private(set) var phase: Phase = .idle
    /// 当前正在录/刚录完的是哪种语言;idle 时为 nil。
    private(set) var language: VoiceprintProfile.Language?
    private(set) var elapsed: Double = 0
    /// 电平表 0…1(峰值,快起慢落)。
    private(set) var level: Double = 0
    /// 已有档案(读自 VoiceprintStore,存/删后同步)。
    private(set) var profiles: [VoiceprintProfile] = []
    /// 档案库都打不开时的说明;此时录制按钮无意义,直接禁掉。
    private(set) var storeError: String?

    var isBusy: Bool {
        switch phase {
        case .preparing, .recording, .processing: true
        case .idle, .message, .failure: false
        }
    }

    var isRecording: Bool { phase == .recording }
    var canSaveNow: Bool { Self.canSave(seconds: elapsed) }

    // AVAudioEngine 懒建:`@State private var recorder = VoiceprintRecorder()` 的默认值
    // 每次父视图 body 求值都会被构造一遍(SwiftUI 随后丢弃多余实例)。设置页里随便敲一个
    // 字符就重求值一次 —— init 必须便宜到无所谓,绝不能在里头建音频引擎或读盘。
    // 档案库同理,改成首次 `loadIfNeeded()` 时才打开。
    @ObservationIgnored private lazy var engine = AVAudioEngine()
    @ObservationIgnored private var store: VoiceprintStore?
    @ObservationIgnored private var injectedStore: VoiceprintStore?
    @ObservationIgnored private var loaded = false
    /// 采集是否已真的起来;stopCapture 据此决定要不要碰 engine(否则会把懒属性建出来)。
    @ObservationIgnored private var captureActive = false
    /// 每次 start 自增。异步的权限请求回来时,若代次已变(用户中途取消/又点了别的),
    /// 这次准备作废 —— 否则取消后 engine 还会被拉起来,phase 被改回 .recording。
    @ObservationIgnored private var generation = 0

    private var samples: [Int16] = []
    @ObservationIgnored private var consumeTask: Task<Void, Never>?
    @ObservationIgnored private var continuation: AsyncStream<[Int16]>.Continuation?

    init(store: VoiceprintStore? = nil) {
        injectedStore = store   // 测试可注入;init 本身不做任何 I/O
    }

    /// 首次显示时打开档案库。幂等。
    func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let injectedStore {
            store = injectedStore
        } else {
            // 打不开就当没有档案库:设置页给出说明,不崩、也不假装能录。
            store = try? VoiceprintStore()
        }
        profiles = store?.profiles ?? []
        if store == nil {
            storeError = "声纹档案库打不开(Application Support 不可写),暂时无法录制。"
        }
    }

    func profile(for language: VoiceprintProfile.Language) -> VoiceprintProfile? {
        profiles.first { $0.language == language }
    }

    /// 该语言的档案是不是别的模型产出的(换模型后要重录)。
    func isStale(_ profile: VoiceprintProfile) -> Bool {
        !profile.isCompatible(withModelID: FluidAudioExtractor.modelID)
    }

    // MARK: - 录制

    func start(language: VoiceprintProfile.Language) {
        loadIfNeeded()
        guard !isBusy, store != nil else { return }
        self.language = language
        samples.removeAll(keepingCapacity: true)
        elapsed = 0
        level = 0
        phase = .preparing
        generation &+= 1
        let gen = generation
        Task { @MainActor in
            guard await PermissionsManager.requestMicrophone() else {
                guard gen == generation else { return }
                phase = .failure("没有麦克风权限 —— 打开 系统设置 → 隐私与安全性 → 麦克风,勾选 LiveSubtitle 后再回来录制。")
                self.language = nil
                return
            }
            // 授权框可能挂很久;回来时用户早已取消或改点了别的,这次准备就此作废。
            guard gen == generation else { return }
            do {
                try beginCapture()
                phase = .recording
            } catch {
                stopCapture()
                phase = .failure("麦克风启动失败:\(error.localizedDescription)")
                self.language = nil
            }
        }
    }

    /// 放弃这次录音,什么也不存。
    func cancel() {
        generation &+= 1        // 作废可能还在等权限的那次准备
        stopCapture()
        samples.removeAll(keepingCapacity: false)
        elapsed = 0
        level = 0
        language = nil
        phase = .idle
    }

    /// 停止录制并保存。不足 `minimumSeconds` 直接拒绝(录到的样本一并丢弃,
    /// 不留一份半截数据在内存里等着被下次误用)。
    func finishAndSave() {
        guard phase == .recording, let language else { return }
        stopCapture()
        let seconds = Double(samples.count) / Self.sampleRate
        guard Self.canSave(seconds: seconds) else {
            samples.removeAll(keepingCapacity: false)
            elapsed = 0
            level = 0
            self.language = nil
            phase = .failure(String(
                format: "只录到 %.1f 秒,不足 %d 秒,没有保存 —— 请重录并把整段文字读完。",
                seconds, Int(Self.minimumSeconds)))
            return
        }
        // 档案库不可用时必须当场认账 —— 下面用 `store?.save` 会静默跳过,
        // 然后照样报「已保存」,那就是凭空捏造一个成功。
        guard let store else {
            samples.removeAll(keepingCapacity: false)
            elapsed = 0
            level = 0
            self.language = nil
            phase = .failure("声纹档案库不可用,这次录音没有保存。")
            return
        }
        let pcm = samples
        samples.removeAll(keepingCapacity: false)
        level = 0
        phase = .processing
        Task { @MainActor in
            do {
                // 首次会下载模型(~13MB)+ ~3s 预热;幂等,和字幕主链路共用同一个抽取器。
                try await CaptionEngine.sharedExtractor.prepare()
                let embedding = try await VoiceprintEnrollment.embedding(
                    for: pcm, using: CaptionEngine.sharedExtractor)
                let profile = VoiceprintProfile(
                    language: language,
                    embedding: embedding,
                    recordedAt: Date(),
                    durationSeconds: seconds,
                    // 盖章:换模型后靠它认出这份档案的向量空间已不通用(见 isCompatible)
                    modelID: FluidAudioExtractor.modelID)
                try store.save(profile)
                profiles = store.profiles
                phase = .message(String(format: "已保存 %@ 声纹(%.0f 秒)。下一场字幕生效。",
                                        language.displayName, seconds))
            } catch {
                phase = .failure("声纹提取失败:\(error.localizedDescription) — 请重试。")
            }
            self.language = nil
        }
    }

    func delete(language: VoiceprintProfile.Language) {
        loadIfNeeded()
        guard !isBusy else { return }
        // 同上:`store?.remove` 在 nil 时静默跳过,不能跟着报「已删除」
        guard let store else {
            phase = .failure("声纹档案库不可用,删不了。")
            return
        }
        do {
            try store.remove(language: language)
            profiles = store.profiles
            phase = .message("已删除 \(language.displayName) 声纹。下一场字幕生效。")
        } catch {
            phase = .failure("删除失败:\(error.localizedDescription)")
        }
    }

    /// 清掉提示条(用户开始下一个动作时)。
    func clearMessage() {
        switch phase {
        case .message, .failure: phase = .idle
        default: break
        }
    }

    // MARK: - 采集

    private static let sampleRate: Double = 16000

    private func beginCapture() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let (stream, cont) = AsyncStream<[Int16]>.makeStream(bufferingPolicy: .bufferingNewest(64))
        continuation = cont
        // 每次录制新建转换器:AVAudioConverter 与源格式绑定,换设备后不能复用。
        let converter = FormatConverter()
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
            guard let mono = FormatConverter.channelZeroMono(buf),
                  let pcm = try? converter.convert(mono) else { return }
            cont.yield(pcm)
        }
        captureActive = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            captureActive = false
            cont.finish()
            continuation = nil
            throw error
        }
        consumeTask = Task { @MainActor [weak self] in
            for await chunk in stream { self?.ingest(chunk) }
        }
    }

    private func stopCapture() {
        consumeTask?.cancel()
        consumeTask = nil
        // 没起过采集就别碰 engine —— 它是懒属性,一碰就白建一个音频引擎出来。
        if captureActive {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            captureActive = false
        }
        continuation?.finish()
        continuation = nil
    }

    private func ingest(_ chunk: [Int16]) {
        guard phase == .recording else { return }   // preparing/已停时来的尾包一律丢弃
        samples.append(contentsOf: chunk)
        elapsed = Double(samples.count) / Self.sampleRate
        var peak: Int32 = 0
        for s in chunk { peak = max(peak, abs(Int32(s))) }
        // 快起慢落:纯峰值会闪成频闪灯,只保留衰减包络才看得出「在收音」
        level = max(min(1.0, Double(peak) / 32768.0), level * 0.8)
        if elapsed >= Self.maximumSeconds { finishAndSave() }
    }
}
