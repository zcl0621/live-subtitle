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
    }
}
