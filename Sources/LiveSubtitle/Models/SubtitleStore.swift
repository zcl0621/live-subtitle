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
    /// 本场会议语种。只在开始字幕那一刻被 CaptionEngine 读取(analyzer 按它构建),中途改不生效。
    var meetingLanguage: MeetingLanguage { didSet { defaults.set(meetingLanguage.rawValue, forKey: "ls.meetingLanguage") } }

    /// 布局编辑态,瞬态(不持久化),启动永远 false。
    var layoutEditing: Bool = false

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
        meetingLanguage = MeetingLanguage(rawValue: defaults.string(forKey: "ls.meetingLanguage") ?? "") ?? .english
        layoutEditing = false
    }

    /// 实际生效的显示模式:中文会议不产译文,含译文的模式一律退化为纯原文。
    /// 否则终句会永远卡在「翻译中…」,`.translatedOnly` 下更是整屏只有占位、看不到字幕。
    var effectiveDisplayMode: DisplayMode {
        meetingLanguage.needsTranslation ? displayMode : .originalOnly
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
            let line = SubtitleLine(speaker: .unresolved(track), original: text, isFinal: false)
            append(line)
            volatileIndex[track] = line.id
        }
    }

    /// 把当前灰字行原地提升为终句(同 id)。若无灰字行则新建一条终句。返回该行 id。
    @discardableResult
    func commitFinal(track: Track, text: String) -> UUID {
        pendingVolatile[track] = nil   // 定稿后丢弃陈旧暂存中间态
        if let id = volatileIndex[track], let i = index(of: id) {
            lines[i].original = text
            lines[i].isFinal = true
            volatileIndex[track] = nil
            return id
        } else {
            let line = SubtitleLine(speaker: .unresolved(track), original: text, isFinal: true)
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
