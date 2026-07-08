import SwiftUI

struct SubtitleBarView: View {
    var store: SubtitleStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(store.lines.suffix(3)) { line in
                HStack(alignment: .top, spacing: 10) {
                    Text(line.speaker == .me ? "我" : "对方")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(line.speaker == .me ? Color.blue : Color.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(line.original)
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(line.isFinal ? 0.6 : 0.4))
                            .italic(!line.isFinal)
                        if let zh = line.translated {
                            Text(zh).font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
                        } else if line.isFinal {
                            Text("翻译中…").font(.system(size: 14)).foregroundStyle(.white.opacity(0.3))
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 900, alignment: .leading)
        .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.1)))
    }
}
