// P6a 探针:FluidAudio 声纹 embedding 中英区分度(KILL 闸门)
//
// 用法(在 probes/p6a_voiceprint/ 下):
//   swift run -c release p6a check           Step 1:模型下载/加载闭环 + 能否只载 embedding 模型
//   swift run -c release p6a embed <音频>     单文件抽 embedding(打印维度/范数/耗时)
//   swift run -c release p6a matrix <目录>    Step 2/3:全对余弦矩阵 + 分组统计 + 阈值建议
//   swift run -c release p6a decay <音频>     Step 4:0.5/1/2/3/5s 前缀 vs 整段 的余弦衰减
//
// matrix 的样本命名约定:<人>_<语言>_<序号>.<wav|m4a|mp3|aiff|caf>
//   例:me_zh_1.wav  me_en_2.m4a  tongshi_zh_1.wav  podcast1_en_1.mp3
//   「我」必须命名为 me;语言用 zh / en。
//
// 结论写 probes/RESULTS.md(P6a 章节)。

@preconcurrency import AVFoundation
import CoreML
import FluidAudio
import Foundation

// MARK: - 音频加载(任意格式 → 16kHz 单声道 Float32)

func loadAudio(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
        throw ProbeError("无法创建 \(file.processingFormat) → 16k mono 的转换器")
    }

    let srcCap = AVAudioFrameCount(8192)
    let srcBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: srcCap)!
    var out: [Float] = []
    var drained = false

    while !drained {
        let dstBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192)!
        var conversionError: NSError?
        let status = converter.convert(to: dstBuf, error: &conversionError) { _, statusPtr in
            do {
                srcBuf.frameLength = 0
                try file.read(into: srcBuf, frameCount: srcCap)
            } catch {
                srcBuf.frameLength = 0
            }
            if srcBuf.frameLength == 0 {
                statusPtr.pointee = .endOfStream
                return nil
            }
            statusPtr.pointee = .haveData
            return srcBuf
        }
        if let conversionError { throw conversionError }
        if status == .error { throw ProbeError("转换失败:\(url.lastPathComponent)") }
        if dstBuf.frameLength > 0 {
            out.append(contentsOf: UnsafeBufferPointer(
                start: dstBuf.floatChannelData![0], count: Int(dstBuf.frameLength)))
        }
        if status == .endOfStream { drained = true }
    }
    return out
}

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - 向量工具

func cosine(_ a: [Float], _ b: [Float]) -> Float {
    precondition(a.count == b.count, "维度不一致:\(a.count) vs \(b.count)")
    var dot: Float = 0, na: Float = 0, nb: Float = 0
    for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    let d = sqrt(na) * sqrt(nb)
    return d > 0 ? dot / d : 0
}

func l2norm(_ v: [Float]) -> Float { sqrt(v.reduce(0) { $0 + $1 * $1 }) }

func stats(_ xs: [Float]) -> String {
    guard !xs.isEmpty else { return "(空)" }
    let sorted = xs.sorted()
    let mean = xs.reduce(0, +) / Float(xs.count)
    let median = sorted[sorted.count / 2]
    return String(
        format: "n=%d  min=%.3f  median=%.3f  mean=%.3f  max=%.3f",
        xs.count, sorted.first!, median, mean, sorted.last!)
}

// MARK: - 抽取器封装(两条路径)

/// 完整路径:DiarizerManager(两个模型都载入)—— 参考基准。
func makeManagerExtractor() async throws -> (DiarizerManager, TimeInterval) {
    let t0 = Date()
    let models = try await DiarizerModels.downloadIfNeeded()
    let manager = DiarizerManager()
    manager.initialize(models: models)
    return (manager, Date().timeIntervalSince(t0))
}

/// 轻量路径:只把 wespeaker_v2.mlmodelc 载入内存,segmentation 模型完全不载。
/// mask 帧数从 embedding 模型自己的输入形状读取 —— 这是 Task 5 想走的路线。
func makeLeanExtractor() throws -> (EmbeddingExtractor, maskFrames: Int, loadSeconds: TimeInterval) {
    let dir = DiarizerModels.defaultModelsDirectory()
    guard let embURL = findModel(named: ModelNames.Diarizer.embeddingFile, under: dir) else {
        throw ProbeError("找不到 \(ModelNames.Diarizer.embeddingFile),先跑 `p6a check` 下载模型(搜索根:\(dir.path))")
    }
    let t0 = Date()
    let config = MLModelConfiguration()
    config.computeUnits = .all
    let model = try MLModel(contentsOf: embURL, configuration: config)
    let load = Date().timeIntervalSince(t0)

    guard
        let maskShape = model.modelDescription.inputDescriptionsByName["mask"]?
            .multiArrayConstraint?.shape,
        maskShape.count >= 2
    else { throw ProbeError("embedding 模型没有可读的 mask 输入形状") }
    let frames = maskShape[1].intValue
    return (EmbeddingExtractor(embeddingModel: model), frames, load)
}

func findModel(named: String, under root: URL) -> URL? {
    let fm = FileManager.default
    // defaultModelsDirectory 的父目录是 ModelHub 的仓库根,模型可能在子目录里,递归找。
    let searchRoot = root.deletingLastPathComponent()
    guard let e = fm.enumerator(at: searchRoot, includingPropertiesForKeys: nil) else { return nil }
    for case let url as URL in e where url.lastPathComponent == named {
        return url
    }
    return nil
}

func leanEmbed(_ extractor: EmbeddingExtractor, maskFrames: Int, audio: [Float]) throws -> [Float] {
    let mask = [Float](repeating: 1.0, count: maskFrames)
    let embeddings = try extractor.getEmbeddings(audio: audio, masks: [mask])
    guard let e = embeddings.first else { throw ProbeError("getEmbeddings 返回空") }
    return e
}

// MARK: - 样本文件枚举

let audioExts = ["wav", "m4a", "mp3", "aiff", "caf", "flac"]

struct Sample {
    let url: URL
    let person: String
    let lang: String
    var label: String { url.deletingPathExtension().lastPathComponent }
}

func enumerateSamples(_ dir: URL) throws -> [Sample] {
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        .filter { audioExts.contains($0.pathExtension.lowercased()) }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    return files.compactMap { url in
        let parts = url.deletingPathExtension().lastPathComponent.split(separator: "_")
        guard parts.count >= 2 else {
            print("⚠️ 跳过不符合命名约定的文件:\(url.lastPathComponent)(需要 <人>_<语言>_<序号>)")
            return nil
        }
        return Sample(url: url, person: String(parts[0]), lang: String(parts[1]))
    }
}

// MARK: - 子命令

func cmdCheck() async throws {
    print("== P6a Step 1:装包闭环 ==\n")

    // 1) 完整路径:下载(如需)+ 双模型加载
    let (manager, fullSetup) = try await makeManagerExtractor()
    print(String(format: "完整路径(DiarizerModels.downloadIfNeeded + 双模型):%.2fs", fullSetup))
    let dir = DiarizerModels.defaultModelsDirectory()
    print("模型目录:\(dir.deletingLastPathComponent().path)")
    for name in [ModelNames.Diarizer.segmentationFile, ModelNames.Diarizer.embeddingFile] {
        if let url = findModel(named: name, under: dir) {
            let size = (try? FileManager.default.allocatedSizeOfDirectory(at: url)) ?? 0
            print(String(format: "  %@  %.1f MB", name, Double(size) / 1_048_576))
        } else {
            print("  \(name)  ❌ 未找到")
        }
    }

    // 2) 用 3s 合成音频冒烟(只验плumbing,不代表真实语音质量)
    let smoke = (0..<48000).map { Float(sin(Double($0) * 2 * .pi * 220 / 16000)) * 0.3 }
    let t1 = Date()
    let refEmb = try manager.extractSpeakerEmbedding(from: smoke)
    let refTime = Date().timeIntervalSince(t1)
    print(String(
        format: "\nextractSpeakerEmbedding(3s 合成音):dim=%d  L2=%.4f  %.0fms",
        refEmb.count, l2norm(refEmb), refTime * 1000))

    // 3) 轻量路径:只载 embedding 模型(spec 未决 1 的答案)
    print("\n== 只载 embedding 模型(跳过 segmentation)==\n")
    let (lean, maskFrames, loadTime) = try makeLeanExtractor()
    print(String(format: "wespeaker_v2 单独加载:%.2fs  mask 帧数(读自模型输入):%d", loadTime, maskFrames))
    let t2 = Date()
    let leanEmb = try leanEmbed(lean, maskFrames: maskFrames, audio: smoke)
    let leanTime = Date().timeIntervalSince(t2)
    let agree = cosine(refEmb, leanEmb)
    print(String(
        format: "轻量路径 embedding:dim=%d  L2=%.4f  %.0fms  与完整路径余弦=%.6f",
        leanEmb.count, l2norm(leanEmb), leanTime * 1000, agree))
    print(agree > 0.999
        ? "✅ 两条路径一致 —— Task 5 可以只载 embedding 模型,不必初始化 segmentation"
        : "❌ 两条路径不一致,Task 5 需按完整 DiarizerManager 路线重估")
}

func cmdEmbed(_ path: String) async throws {
    let (manager, _) = try await makeManagerExtractor()
    let audio = try loadAudio(URL(fileURLWithPath: path))
    print(String(format: "样本:%@  %.1fs @16k", path, Double(audio.count) / 16000))
    let t = Date()
    let emb = try manager.extractSpeakerEmbedding(from: audio)
    print(String(
        format: "dim=%d  L2=%.4f  耗时 %.0fms", emb.count, l2norm(emb),
        Date().timeIntervalSince(t) * 1000))
    print("前 8 维:", emb.prefix(8).map { String(format: "%.4f", $0) }.joined(separator: " "))
}

func cmdMatrix(_ dirPath: String) async throws {
    let samples = try enumerateSamples(URL(fileURLWithPath: dirPath, isDirectory: true))
    guard samples.count >= 2 else { throw ProbeError("目录里至少要 2 个符合命名约定的音频文件") }

    let (manager, _) = try await makeManagerExtractor()
    print("== 抽 embedding(\(samples.count) 个样本)==")
    var embs: [(Sample, [Float])] = []
    for s in samples {
        let audio = try loadAudio(s.url)
        let secs = Double(audio.count) / 16000
        if secs < 15 { print(String(format: "⚠️ %@ 只有 %.1fs(建议 ≥20s)", s.label, secs)) }
        let e = try manager.extractSpeakerEmbedding(from: audio)
        embs.append((s, e))
        print(String(format: "  %@  %.1fs  L2=%.3f", s.label, secs, l2norm(e)))
    }

    // 全对矩阵
    print("\n== 余弦矩阵 ==")
    let labels = embs.map { $0.0.label }
    let w = max(10, (labels.map(\.count).max() ?? 10) + 2)
    print(String(repeating: " ", count: w) + labels.map { $0.padding(toLength: w, withPad: " ", startingAt: 0) }.joined())
    for (i, (si, ei)) in embs.enumerated() {
        var row = si.label.padding(toLength: w, withPad: " ", startingAt: 0)
        for (j, (_, ej)) in embs.enumerated() {
            row += (i == j ? "   —  " : String(format: "%6.3f", cosine(ei, ej)))
                .padding(toLength: w, withPad: " ", startingAt: 0)
        }
        print(row)
    }

    // 分组统计
    var samePersonSameLang: [String: [Float]] = [:]   // 按语言
    var crossPersonSameLang: [String: [Float]] = [:]
    var samePersonCrossLang: [Float] = []
    for i in 0..<embs.count {
        for j in (i + 1)..<embs.count {
            let (a, ea) = embs[i], (b, eb) = embs[j]
            let c = cosine(ea, eb)
            if a.person == b.person, a.lang == b.lang {
                samePersonSameLang[a.lang, default: []].append(c)
            } else if a.person != b.person, a.lang == b.lang {
                crossPersonSameLang[a.lang, default: []].append(c)
            } else if a.person == b.person {
                samePersonCrossLang.append(c)
            }
        }
    }

    print("\n== 分组统计(Step 2 判定依据)==")
    for lang in Set(samePersonSameLang.keys).union(crossPersonSameLang.keys).sorted() {
        print("[\(lang)] 同人同语言:\(stats(samePersonSameLang[lang] ?? []))")
        print("[\(lang)] 异人同语言:\(stats(crossPersonSameLang[lang] ?? []))")
        if let same = samePersonSameLang[lang]?.min(),
           let cross = crossPersonSameLang[lang]?.max() {
            let sep = same - cross
            print(String(
                format: "[%@] 间隔 = 同人min(%.3f) − 异人max(%.3f) = %+.3f  %@",
                lang, same, cross, sep, sep > 0 ? "✅ 可分" : "❌ 重叠"))
            if sep > 0 {
                print(String(
                    format: "[%@] θ 建议区间:θ_cluster ≈ %.2f,θ_me ≥ %.2f(异人max上尾之外,宁漏勿误)",
                    lang, cross + sep * 0.3, cross + sep * 0.6))
            }
        }
        print()
    }
    if !samePersonCrossLang.isEmpty {
        print("同人跨语言(不用于判定,白拿的数据):\(stats(samePersonCrossLang))")
    }
}

func cmdDecay(_ path: String) async throws {
    let (manager, _) = try await makeManagerExtractor()
    let audio = try loadAudio(URL(fileURLWithPath: path))
    let total = Double(audio.count) / 16000
    guard total >= 6 else { throw ProbeError("样本至少要 6s(现在 \(String(format: "%.1f", total))s)") }
    let full = try manager.extractSpeakerEmbedding(from: audio)
    print(String(format: "整段 %.1fs 为基准,前缀余弦:", total))
    for secs in [0.5, 1.0, 2.0, 3.0, 5.0] {
        let n = Int(secs * 16000)
        let e = try manager.extractSpeakerEmbedding(from: Array(audio[0..<n]))
        print(String(format: "  %.1fs → %.3f", secs, cosine(e, full)))
    }
    print("(spec §2 的短句兜底 1.0s 阈值按这条曲线校正)")
}

// MARK: - 目录大小小工具

extension FileManager {
    func allocatedSizeOfDirectory(at url: URL) throws -> Int64 {
        var size: Int64 = 0
        if let e = enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) {
            for case let f as URL in e {
                size += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize ?? 0)
            }
        }
        return size
    }
}

// MARK: - 入口

let args = CommandLine.arguments
func usage() -> Never {
    print("""
    用法:swift run -c release p6a <check|embed|matrix|decay> [参数]
      check          模型下载/加载闭环 + 轻量路径验证
      embed <音频>    单文件抽 embedding
      matrix <目录>   全对余弦 + 分组统计 + 阈值建议(命名:<人>_<语言>_<序号>.wav)
      decay <音频>    短音频前缀衰减曲线(样本 ≥6s)
    """)
    exit(1)
}

guard args.count >= 2 else { usage() }
do {
    switch args[1] {
    case "check": try await cmdCheck()
    case "embed" where args.count >= 3: try await cmdEmbed(args[2])
    case "matrix" where args.count >= 3: try await cmdMatrix(args[2])
    case "decay" where args.count >= 3: try await cmdDecay(args[2])
    default: usage()
    }
} catch {
    print("❌ \(error)")
    exit(1)
}
