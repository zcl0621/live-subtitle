import Foundation

/// ⚠️ **临时诊断日志,Task 10 验收定位完就整体撤掉,不要让它进主干。**
///
/// 为什么写文件而不是 NSLog:这台 Mac(macOS 27)上 NSLog 不进 unified logging,
/// `log show` 取不到;而 app 是经 `open build/LiveSubtitle.app` 启动的,stderr 直接被丢弃。
/// 写 /tmp 是唯一能稳定拿到的通道。
enum Diag {
    static let path = "/tmp/livesubtitle-diag.log"
    private static let queue = DispatchQueue(label: "ls.diag")
    private static let started = Date()

    static func write(_ msg: String) {
        let line = String(format: "[%8.3f] %@\n", Date().timeIntervalSince(started), msg)
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let fh = FileHandle(forWritingAtPath: path) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: path))
            }
        }
    }
}

/// 全局诊断打点。撤掉诊断时把本文件删掉,编译器会把所有调用点报给你。
func lslog(_ msg: String) { Diag.write(msg) }
