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

    /// 布局编辑态,瞬态(不持久化),启动永远 false。
    var layoutEditing: Bool = false

    /// 每个 speaker 的"当前未定稿灰字行"索引;定稿后清除。
    private var volatileIndex: [Speaker: Int] = [:]

    /// 每个 speaker 的暂存中间态,尚未上屏(由节流器 flush)。
    private var pendingVolatile: [Speaker: String] = [:]

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
        layoutEditing = false
    }

    /// 暂存中间态,不立即上屏(由节流器 flush)。
    func stageVolatile(speaker: Speaker, text: String) {
        pendingVolatile[speaker] = text
    }

    /// 把所有暂存的中间态一次性上屏。
    func flushVolatile() {
        for (speaker, text) in pendingVolatile {
            upsertVolatile(speaker: speaker, text: text)
        }
        pendingVolatile.removeAll()
    }

    func upsertVolatile(speaker: Speaker, text: String) {
        if let i = volatileIndex[speaker] {
            lines[i].original = text
        } else {
            lines.append(SubtitleLine(speaker: speaker, original: text, isFinal: false))
            volatileIndex[speaker] = lines.count - 1
        }
    }

    /// 把当前灰字行原地提升为终句(同 id)。若无灰字行则新建一条终句。返回该行 id。
    @discardableResult
    func commitFinal(speaker: Speaker, text: String) -> UUID {
        pendingVolatile[speaker] = nil   // 定稿后丢弃陈旧暂存中间态
        if let i = volatileIndex[speaker] {
            lines[i].original = text
            lines[i].isFinal = true
            volatileIndex[speaker] = nil
            return lines[i].id
        } else {
            let line = SubtitleLine(speaker: speaker, original: text, isFinal: true)
            lines.append(line)
            return line.id
        }
    }

    func attachTranslation(id: UUID, zh: String) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        lines[i].translated = zh
        lines[i].translationFailed = false   // 成功则清除任何旧的失败标记
    }

    /// 翻译尝试失败:打标记,UI 据此回退显原文而非永久「翻译中…」。
    func markTranslationFailed(id: UUID) {
        guard let i = lines.firstIndex(where: { $0.id == id }) else { return }
        if lines[i].translated == nil { lines[i].translationFailed = true }
    }

    /// 当前某 speaker 未定稿中间态的原文(供边说边译读取);无则 nil。
    func currentVolatileText(speaker: Speaker) -> String? {
        guard let i = volatileIndex[speaker] else { return nil }
        return lines[i].original
    }

    /// 回填中间态译文:仅当该 speaker 的中间态行仍存在、仍未定稿、且原文未变(== sourceText)时才应用,
    /// 避免把过期片段的译文贴到已被新内容替换或已定稿的行上。
    func attachVolatileTranslation(speaker: Speaker, sourceText: String, zh: String) {
        guard let i = volatileIndex[speaker], !lines[i].isFinal, lines[i].original == sourceText else { return }
        lines[i].translated = zh
    }
}
