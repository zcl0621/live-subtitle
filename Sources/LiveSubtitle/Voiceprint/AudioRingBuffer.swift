import Foundation

/// 定长环形缓冲,按「累计写入样本序号」寻址。
/// 线程约束:仅由所属轨的采集回调写、由归属判定读,调用方自行保证串行(实践中同一 actor)。
final class AudioRingBuffer {
    private var storage: [Int16]
    private let capacity: Int
    /// 已累计写入的样本总数;也是下一个写入位置的绝对序号。
    private(set) var written: Int = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.storage = Array(repeating: 0, count: capacity)
    }

    /// 当前仍可读取的最早绝对序号。
    var earliestAvailable: Int { max(0, written - capacity) }

    func append(_ samples: [Int16]) {
        for s in samples {
            storage[written % capacity] = s
            written += 1
        }
    }

    /// 取 [from, from+count) 的样本;越界(已被覆盖 / 尚未写入)返回 nil,count <= 0 亦返回 nil。
    func slice(from: Int, count: Int) -> [Int16]? {
        guard count > 0, from >= earliestAvailable, from + count <= written else { return nil }
        var out = [Int16]()
        out.reserveCapacity(count)
        for i in from..<(from + count) { out.append(storage[i % capacity]) }
        return out
    }

    /// 按秒区间取样本(秒 → 样本序号)。
    func slice(seconds: Range<Double>, sampleRate: Int) -> [Int16]? {
        let start = Int(seconds.lowerBound * Double(sampleRate))
        let end = Int(seconds.upperBound * Double(sampleRate))
        return slice(from: start, count: end - start)
    }
}
