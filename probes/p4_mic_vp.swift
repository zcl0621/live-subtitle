// P4 探针 — AVAudioEngine 麦克风 + Voice Processing(AEC 回声消除)
// 验:1) setVoiceProcessingEnabled 能否开 2) 麦克风能否采到 3) VP 下的 tap 格式
// 注:完整"外放回声消除干净度"是声学测试(需外放+人说话),此探针只验 API + 采集通路。
// 编译:swiftc -target arm64-apple-macos26.0 -parse-as-library probes/p4_mic_vp.swift -o /tmp/p4 && /tmp/p4
import Foundation
import AVFoundation

func emit(_ s: String) {
    print(s)
    let h = FileHandle(forWritingAtPath: "/tmp/p4_result.txt")
    h?.seekToEndOfFile(); h?.write((s + "\n").data(using: .utf8)!); h?.closeFile()
}

@main
struct P4 {
    static func main() async {
        try? "".write(toFile: "/tmp/p4_result.txt", atomically: true, encoding: .utf8)
        emit("== P4 探针:AVAudioEngine mic + Voice Processing == (\(Date()))")

        // 请求麦克风权限(CLI 下归属宿主 app)
        let granted = await AVAudioApplication.requestRecordPermission()
        emit("[0] 麦克风权限:\(granted ? "已授权" : "被拒/未授权")")
        guard granted else {
            emit("→ 未授权:系统设置 → 隐私与安全 → 麦克风,允许宿主 app(Claude),再跑")
            exit(1)
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode

        // 关键:必须在 engine stop 态开 VP
        do {
            try input.setVoiceProcessingEnabled(true)
            emit("[1] setVoiceProcessingEnabled(true) 成功(AEC/降噪开启)")
        } catch {
            emit("[1] setVoiceProcessingEnabled 失败:\(error)")
        }

        let fmt = input.outputFormat(forBus: 0)
        let isFloat = fmt.commonFormat == .pcmFormatFloat32
        emit("[2] VP 下 tap 格式:\(fmt.sampleRate)Hz, \(fmt.channelCount)ch, common=\(fmt.commonFormat.rawValue)(\(isFloat ? "Float32" : "其他"))")

        var frames = 0
        var peak: Float = 0
        var tapFmtLogged = false
        // 关键修正:tap 用 format: nil,让引擎按节点真实格式给 buffer(VP 改格式后固定格式会 0 样本)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buf, _ in
            if !tapFmtLogged { emit("    [tap 实际格式] \(buf.format.sampleRate)Hz, \(buf.format.channelCount)ch"); tapFmtLogged = true }
            frames += Int(buf.frameLength)
            if let ch = buf.floatChannelData {
                let n = Int(buf.frameLength)
                for i in 0..<n { let v = abs(ch[0][i]); if v > peak { peak = v } }
            }
        }

        do {
            try engine.start()
            emit("[3] 引擎启动,采集 4s(随便说点话)...")
            try await Task.sleep(for: .seconds(4))
            engine.stop()
            input.removeTap(onBus: 0)
            emit("[4] 结果:采到 \(frames) 样本 ≈ \(String(format: "%.2f", Double(frames)/fmt.sampleRate))s;峰值 \(String(format: "%.4f", peak))")
            emit(frames > 0 ? "    ✅ 麦克风 + VP 通路成立(采到\(peak > 0.001 ? "非静音" : "静音,可能没说话")音频)" : "    ⚠️ 没采到音频")
            emit("[5] 回声消除干净度:需外放场景声学实测(本探针不覆盖);戴耳机=最稳(天然无回声)")
        } catch {
            emit("[3] 引擎启动失败:\(error)")
            exit(1)
        }
    }
}
