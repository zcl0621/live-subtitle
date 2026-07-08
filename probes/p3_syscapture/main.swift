// P3 探针 — ScreenCaptureKit 纯系统音频采集(macOS)
// 验:1) 只采系统音频(不要视频)拿到 PCM 2) 屏录 TCC 授权流 3) 回调形态
// 需 .app bundle(Info.plist 带 NSScreenCaptureUsageDescription)+ 屏录授权。
import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

final class Recorder: NSObject, SCStreamOutput, SCStreamDelegate {
    var audioBuffers = 0
    var totalSamples = 0
    var maxAbs: Float = 0
    let done = DispatchSemaphore(value: 0)

    var printedFormat = false
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        audioBuffers += 1
        totalSamples += CMSampleBufferGetNumSamples(sampleBuffer)

        // 首帧打印真实音频格式(采样率/声道/float还是int)
        if !printedFormat, let fd = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
            let isFloat = asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
            emit("    [格式] \(asbd.pointee.mSampleRate)Hz, \(asbd.pointee.mChannelsPerFrame)ch, \(isFloat ? "Float" : "Int"), bits=\(asbd.pointee.mBitsPerChannel)")
            printedFormat = true
        }

        // 取 block buffer 原始指针算峰值(按 float/int 正确解释)
        guard let bb = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        var len = 0; var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr) == kCMBlockBufferNoErr, let raw = ptr else { return }
        let isFloat = (CMSampleBufferGetFormatDescription(sampleBuffer).flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0) }?.pointee.mFormatFlags ?? 0) & kAudioFormatFlagIsFloat != 0
        if isFloat {
            let cnt = len / MemoryLayout<Float>.size
            raw.withMemoryRebound(to: Float.self, capacity: cnt) { p in
                for i in 0..<cnt { let v = abs(p[i]); if v > maxAbs { maxAbs = v } }
            }
        } else {
            let cnt = len / MemoryLayout<Int16>.size
            raw.withMemoryRebound(to: Int16.self, capacity: cnt) { p in
                for i in 0..<cnt { let v = abs(Float(p[i]))/Float(Int16.max); if v > maxAbs { maxAbs = v } }
            }
        }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[stream 停止错误] \(error)")
        done.signal()
    }
}

func emit(_ s: String) {
    print(s)
    if let h = FileHandle(forWritingAtPath: "/tmp/p3_result.txt") ?? { FileManager.default.createFile(atPath: "/tmp/p3_result.txt", contents: nil); return FileHandle(forWritingAtPath: "/tmp/p3_result.txt") }() {
        h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); h.closeFile()
    }
}

@main
struct P3 {
    static func main() async {
        try? "".write(toFile: "/tmp/p3_result.txt", atomically: true, encoding: .utf8)
        emit("== P3 探针:ScreenCaptureKit 纯系统音频 == (\(Date()))")
        do {
            emit("[1] 请求可共享内容(首次会触发屏录授权)...")
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else { emit("无显示器"); exit(1) }
            emit("[1] 拿到显示器 \(display.width)x\(display.height);可见 app \(content.applications.count) 个")

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            let config = SCStreamConfiguration()
            config.capturesAudio = true
            config.excludesCurrentProcessAudio = true
            config.sampleRate = 48_000
            config.channelCount = 2
            config.width = 2; config.height = 2   // 只要音频,视频给最小

            let rec = Recorder()
            let stream = SCStream(filter: filter, configuration: config, delegate: rec)
            try stream.addStreamOutput(rec, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio"))
            emit("[2] 开始采集 6s(后台在放音频)...")
            try await stream.startCapture()
            try await Task.sleep(for: .seconds(6))
            try await stream.stopCapture()

            emit("[3] 结果:")
            emit("    音频回调次数 \(rec.audioBuffers)")
            emit("    累计样本 \(rec.totalSamples) ≈ \(String(format: "%.2f", Double(rec.totalSamples)/48000.0))s")
            emit("    峰值(0~1,>0 即非静音)\(String(format: "%.4f", rec.maxAbs))")
            emit(rec.audioBuffers > 0 && rec.maxAbs > 0.001 ? "    ✅ 成功拿到非静音系统音频" : "    ⚠️ 有回调但静音/无回调(可能没播声音或被排除)")
        } catch {
            emit("[错误] \(error)")
            emit("→ TCC 拒绝:系统设置 → 隐私与安全 → 屏幕与系统录音 → 勾选 P3Probe,再跑")
            exit(1)
        }
    }
}
