import Foundation
import Observation

@MainActor
@Observable
final class SubtitleStore {
    private let defaults: UserDefaults
    private(set) var lines: [SubtitleLine] = []      // 全量内存历史(不落盘)

    var displayMode: DisplayMode { didSet { defaults.set(displayMode.rawValue, forKey: "ls.displayMode") } }
    var overlayMode: OverlayMode { didSet { defaults.set(overlayMode.rawValue, forKey: "ls.overlayMode") } }
    var opacity: Double { didSet { defaults.set(opacity, forKey: "ls.opacity") } }
    var fontSize: Double { didSet { defaults.set(fontSize, forKey: "ls.fontSize") } }
    var pinned: Bool { didSet { defaults.set(pinned, forKey: "ls.pinned") } }
    var barWidth: Double { didSet { defaults.set(barWidth, forKey: "ls.barWidth") } }
    var deepSeekAPIKey: String { didSet { defaults.set(deepSeekAPIKey, forKey: "ls.deepSeekKey") } }
    var obsidianVaultPath: String { didSet { defaults.set(obsidianVaultPath, forKey: "ls.vaultPath") } }
    /// 边说边译:对未定稿的中间态也翻译(降延迟,代价是译文会随句子生长而跳变)。
    var translateVolatile: Bool { didSet { defaults.set(translateVolatile, forKey: "ls.translateVolatile") } }
    /// 会议语种设置 =【下一场】用哪种语种开字幕。改它不影响已在跑的这一场:
    /// CaptionEngine 在 start 那一刻把它快照进 sessionLanguage,analyzer 也按快照构建。
    var meetingLanguage: MeetingLanguage { didSet { defaults.set(meetingLanguage.rawValue, forKey: "ls.meetingLanguage") } }

    // MARK: - 声纹判定阈值(spec §2「两个阈值都放设置页可调」)

    /// 可调区间与档距。区间下限 0.3 / 上限 0.9 是围着 P6c 实测分布留的活动范围
    /// (同人最低 ~0.68、异人最高 ~0.42),不是模型的硬边界。
    static let thresholdRange: ClosedRange<Double> = 0.3...0.9
    static let thresholdStep: Double = 0.05
    /// θ_me 与 θ_cluster 之间至少留一档。**这是 spec §2 的不对称约束的执行点**:
    /// θ_me > θ_cluster —— 把别人误判成「我」比漏判「我」更糟(会污染 Obsidian 导出的归属)。
    static let minThresholdGap: Double = 0.05
    /// P6c 实测定值。真值在 `SpeakerAttributor` 上(判定逻辑那一侧才是源头),
    /// 这里只是把它换成设置页用的 Double —— 不另抄一份字面量。
    static let defaultThresholdMe = Double(SpeakerAttributor.defaultThresholdMe)
    static let defaultThresholdCluster = Double(SpeakerAttributor.defaultThresholdCluster)

    /// θ_me:与「我」的档案余弦 ≥ 此值即判定为「我」。调低 = 更容易认成「我」。
    /// 只在【下一场】生效:SpeakerAttributor 在 CaptionEngine.init 那一刻按它构建
    /// (UI 侧运行中把滑杆置灰,语义与语种 Picker 一致)。
    var thresholdMe: Double {
        didSet {
            let n = Self.normalizedThresholds(me: thresholdMe, cluster: thresholdCluster)
            // 在自己的 didSet 里赋值不会再次触发 didSet(Swift 语义),故不会递归
            if n.me != thresholdMe { thresholdMe = n.me }
            defaults.set(thresholdMe, forKey: "ls.thresholdMe")
            // θ_me 降到 θ_cluster 头上时,把 θ_cluster 一起压下去(见 normalizedThresholds)
            if n.cluster != thresholdCluster { thresholdCluster = n.cluster }
        }
    }

    /// θ_cluster:与已有簇心余弦 ≥ 此值即并入该簇。调低 = 更容易把两个人并成一个;
    /// 调高 = 簇爆炸(同一人被拆成多个「说话人 N」)。
    var thresholdCluster: Double {
        didSet {
            let n = Self.normalizedThresholds(me: thresholdMe, cluster: thresholdCluster)
            if n.cluster != thresholdCluster { thresholdCluster = n.cluster }
            defaults.set(thresholdCluster, forKey: "ls.thresholdCluster")
        }
    }

    /// 夹紧到合法区间,并守住 θ_me > θ_cluster。
    ///
    /// **θ_me 是锚,冲突时让 θ_cluster 让步**:θ_me 管的是「别把别人认成我」这件更贵的错,
    /// 不该被一次对 θ_cluster 的调整悄悄拉高或拉低。故 θ_me 只夹到区间内
    /// (下限再抬一档,保证 θ_cluster 总有合法落点),θ_cluster 额外夹在 θ_me 之下。
    static func normalizedThresholds(me: Double, cluster: Double) -> (me: Double, cluster: Double) {
        let m = min(max(me, thresholdRange.lowerBound + minThresholdGap), thresholdRange.upperBound)
        let c = min(max(cluster, thresholdRange.lowerBound), m - minThresholdGap)
        return (m, c)
    }

    /// 布局编辑态,瞬态(不持久化),启动永远 false。
    var layoutEditing: Bool = false

    /// 当前屏上这批字幕【实际产自】哪种语种的会议 —— 由 CaptionEngine.init 写入的事实,
    /// 不是用户的下一场选择。瞬态(不持久化),启动跟随 meetingLanguage。
    /// 独立成一份的原因:停止后用户把设置改成中文,不该让屏上已有的英文行连带丢掉译文。
    var sessionLanguage: MeetingLanguage

    /// 本场会议的标识,瞬态。每次 `beginSession`(CaptionEngine 开一场)换新,
    /// 上屏的每一行都盖上当时的章。存在的理由:`lines` 跨会话不清空(见 beginSession),
    /// 导出必须能把「这一场」从历史里切出来 —— 见 `ObsidianExporter.lastSessionLines`。
    private(set) var sessionID = UUID()

    /// 字幕是否正在运行,瞬态(不持久化),启动永远 false。
    /// 放 store 而非 App 的 @State:设置页要据此把语种 Picker 置灰,穿参数传不进 Settings scene 才是绕路。
    var isRunning: Bool = false

    /// 说话人改名映射。**瞬态,故意不持久化**:簇号是会话内在线聚类的产物,
    /// 下一场会议的「说话人 2」和这一场的多半不是同一个人,存下来只会张冠李戴
    /// —— 宁可每场重新改一次名,也不要一个会自信地叫错人的字幕。
    ///
    /// 键是 `SpeakerID.Kind` 而不是整个 `SpeakerID`:两条轨共用同一个
    /// `SpeakerClusterer`、centroids 是单一数组,所以 `.cluster(3)` 无论出现在
    /// mic 还是 system 轨都指同一个 centroid = 同一个人。配色本来就按 kind 忽略轨
    /// (同簇同色),改名若按 (track, kind) 分开,用户会看到两个同色同名的 chip,
    /// 改了一个却只有一半的行跟着变。
    var speakerNames: [SpeakerID.Kind: String] = [:]

    /// 上一场的改名映射已过期,但**还没作废** —— 等本场第一条终句到来时才清。
    ///
    /// 为什么不在 `beginSession` 当场清:导出锚在【最后一条终句】所在的那一场
    /// (`ObsidianExporter.lastSessionLines`),本场还没出终句时,该导出的仍是上一场那批行。
    /// 当场清就会拿一份空映射去导上一场的行,用户刚改的「老王」在笔记里变回「说话人 2」。
    /// 两处必须用同一个时刻切换:第一条终句既把导出锚点挪到本场,也让上一场的改名作废。
    private var renamesPendingExpiry = false

    /// 每条轨的"当前未定稿灰字行"id;定稿后清除。
    /// 用 id(而非绝对下标),这样截断旧行后仍能正确定位,不会失效或错位。
    private var volatileIndex: [Track: UUID] = [:]

    /// id → lines 下标,O(1) 定位;避免每次终句翻译回填做 O(n) firstIndex 扫描。截断时重建。
    private var indexByID: [UUID: Int] = [:]

    /// 每条轨的暂存中间态,尚未上屏(由节流器 flush)。
    private var pendingVolatile: [Track: String] = [:]

    /// 保留的最大行数上限;超出则从最旧行开始丢弃,避免长会话内存/渲染无界增长。
    /// 取值足够大,正常通话/会议不会触及;导出用当前保留的行(极长会话会丢最早的回看历史)。
    private let maxLines = 2000

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "ls.displayMode") ?? "") ?? .both
        overlayMode = OverlayMode(rawValue: defaults.string(forKey: "ls.overlayMode") ?? "") ?? .bar
        opacity = defaults.object(forKey: "ls.opacity") as? Double ?? 0.82
        fontSize = defaults.object(forKey: "ls.fontSize") as? Double ?? 22
        pinned = defaults.bool(forKey: "ls.pinned")
        barWidth = defaults.object(forKey: "ls.barWidth") as? Double ?? 900
        deepSeekAPIKey = defaults.string(forKey: "ls.deepSeekKey") ?? ""
        obsidianVaultPath = defaults.string(forKey: "ls.vaultPath") ?? ""
        translateVolatile = defaults.object(forKey: "ls.translateVolatile") as? Bool ?? true
        let language = MeetingLanguage(rawValue: defaults.string(forKey: "ls.meetingLanguage") ?? "") ?? .english
        meetingLanguage = language
        // 初始化期间 didSet 不跑,故在这里显式过一遍规范化:落盘的值可能来自旧版本、
        // 手改的 plist 或另一台机器的同步,不能假定它满足区间与 θ_me > θ_cluster。
        let normalized = Self.normalizedThresholds(
            me: defaults.object(forKey: "ls.thresholdMe") as? Double ?? Self.defaultThresholdMe,
            cluster: defaults.object(forKey: "ls.thresholdCluster") as? Double ?? Self.defaultThresholdCluster)
        thresholdMe = normalized.me
        thresholdCluster = normalized.cluster
        sessionLanguage = language      // 未开过字幕时,"本场"就等于设置
        layoutEditing = false
        isRunning = false
    }

    /// 实际生效的显示模式:中文会议不产译文,含译文的模式一律退化为纯原文。
    /// 否则终句会永远卡在「翻译中…」,`.translatedOnly` 下更是整屏只有占位、看不到字幕。
    /// 读 sessionLanguage(屏上这批行的事实)而非 meetingLanguage(下一场的选择)。
    var effectiveDisplayMode: DisplayMode {
        sessionLanguage.needsTranslation ? displayMode : .originalOnly
    }

    /// 开一场新会议(由 `CaptionEngine.init` 调用),盖新的 sessionID 并定格本场语种。
    ///
    /// **故意不清空 `lines`**:导出按 sessionID 分段,历史留在屏上可回看。
    /// 若在此 removeAll,「停止 → 再开始」(中途暂停、权限重试、误点停止)就会把
    /// 还没导出的上一场当场销毁 —— 主按钮上两下点没了一整场会议,代价远高于收益。
    func beginSession(language: MeetingLanguage) {
        sessionLanguage = language
        sessionID = UUID()
        // 上一场遗留的灰字行不再当作本场的中间态复用:否则本场第一句会去改写一条盖着
        // 上一场章的行,定稿后既插在历史中间、又落在本场的导出分段之外。
        volatileIndex.removeAll()
        pendingVolatile.removeAll()
        // 改名同样要作废(本场是全新 clusterer,簇号从 0 重编,本场的「说话人 2」与上一场
        // 多半不是同一个人;留着映射 = 自信地叫错人),但**推迟到本场第一条终句**再清
        // —— 在那之前导出取的还是上一场的行,理由见 renamesPendingExpiry。
        renamesPendingExpiry = true
    }

    /// 本场产出第一条终句 = 导出锚点从上一场挪到本场,上一场的改名就此作废。
    private func expireRenamesIfNeeded() {
        guard renamesPendingExpiry else { return }
        renamesPendingExpiry = false
        speakerNames.removeAll()
    }

    /// 该说话人当前该显示成什么名字(改名优先,否则用默认名)。
    func displayName(for speaker: SpeakerID) -> String {
        speaker.displayName(overrides: speakerNames)
    }

    /// 改名。空白名 = 恢复默认(而不是存一个空标签把人的身份抹成空白)。
    /// 按 kind 生效,两条轨上的同一个人一起改。
    func rename(_ speaker: SpeakerID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            speakerNames[speaker.kind] = nil
        } else {
            speakerNames[speaker.kind] = trimmed
        }
    }

    /// 暂存中间态,不立即上屏(由节流器 flush)。
    func stageVolatile(track: Track, text: String) {
        pendingVolatile[track] = text
    }

    /// 把所有暂存的中间态一次性上屏。
    func flushVolatile() {
        for (track, text) in pendingVolatile {
            upsertVolatile(track: track, text: text)
        }
        pendingVolatile.removeAll()
    }

    func upsertVolatile(track: Track, text: String) {
        if let id = volatileIndex[track], let i = index(of: id) {
            lines[i].original = text
        } else {
            let line = SubtitleLine(sessionID: sessionID, speaker: .unresolved(track), original: text, isFinal: false)
            append(line)
            volatileIndex[track] = line.id
        }
    }

    /// 把当前灰字行原地提升为终句(同 id)。若无灰字行则新建一条终句。返回该行 id。
    @discardableResult
    func commitFinal(track: Track, text: String) -> UUID {
        expireRenamesIfNeeded()        // 本场第一条终句 → 上一场的改名作废(与导出锚点同一刻)
        pendingVolatile[track] = nil   // 定稿后丢弃陈旧暂存中间态
        if let id = volatileIndex[track], let i = index(of: id) {
            lines[i].original = text
            lines[i].isFinal = true
            volatileIndex[track] = nil
            return id
        } else {
            let line = SubtitleLine(sessionID: sessionID, speaker: .unresolved(track), original: text, isFinal: true)
            append(line)
            return line.id
        }
    }

    func attachTranslation(id: UUID, zh: String) {
        guard let i = index(of: id) else { return }
        lines[i].translated = zh
        lines[i].translationFailed = false      // 成功则清除任何旧的失败标记
        lines[i].translationProvisional = false // 定稿译文,不再是临时半句
    }

    /// 声纹判定回填:终句归属出来后按 id 更新说话人(判定是异步的,行早已上屏)。
    func attachSpeaker(id: UUID, speaker: SpeakerID) {
        guard let i = index(of: id) else { return }
        lines[i].speaker = speaker
    }

    /// 翻译尝试失败:打标记,UI 据此回退显原文而非永久「翻译中…」或残留的半句译文。
    /// 未翻译(nil)或仅有中间态临时译文(provisional)时都视为失败并清掉临时译文。
    func markTranslationFailed(id: UUID) {
        guard let i = index(of: id) else { return }
        if lines[i].translated == nil || lines[i].translationProvisional {
            lines[i].translated = nil
            lines[i].translationProvisional = false
            lines[i].translationFailed = true
        }
    }

    /// 当前某轨未定稿中间态的原文(供边说边译读取);无则 nil。
    func currentVolatileText(track: Track) -> String? {
        guard let id = volatileIndex[track], let i = index(of: id) else { return nil }
        return lines[i].original
    }

    /// 回填中间态译文:仅当该轨的中间态行仍存在、仍未定稿、且原文未变(== sourceText)时才应用,
    /// 避免把过期片段的译文贴到已被新内容替换或已定稿的行上。
    func attachVolatileTranslation(track: Track, sourceText: String, zh: String) {
        guard let id = volatileIndex[track], let i = index(of: id),
              !lines[i].isFinal, lines[i].original == sourceText else { return }
        lines[i].translated = zh
        lines[i].translationProvisional = true   // 半句临时译文;终句译文到位或失败时会被覆盖/清除
    }

    // MARK: - 内部:索引维护 + 截断

    private func index(of id: UUID) -> Int? { indexByID[id] }

    /// 追加一行,维护 indexByID,并在超限时截断。
    private func append(_ line: SubtitleLine) {
        lines.append(line)
        indexByID[line.id] = lines.count - 1
        trimIfNeeded()
    }

    /// 超过上限则丢弃最旧的行并重建 indexByID。当前未定稿行总在尾部,不会被丢。
    private func trimIfNeeded() {
        guard lines.count > maxLines else { return }
        lines.removeFirst(lines.count - maxLines)
        indexByID.removeAll(keepingCapacity: true)
        for (i, line) in lines.enumerated() { indexByID[line.id] = i }
    }
}
