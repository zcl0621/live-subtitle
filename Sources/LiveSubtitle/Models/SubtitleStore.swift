import Foundation
import Observation

@MainActor
@Observable
final class SubtitleStore {
    private(set) var lines: [SubtitleLine] = []      // 全量内存历史(不落盘)
    var displayMode: DisplayMode = .both             // Phase 1 固定
    var overlayMode: OverlayMode = .bar

    /// 每个 speaker 的"当前未定稿灰字行"索引;定稿后清除。
    private var volatileIndex: [Speaker: Int] = [:]

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
