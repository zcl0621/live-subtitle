// 生成 LiveSubtitle 应用图标(纯 AppKit 绘制,无外部依赖)。
// 用法: swift scripts/make-icon.swift [输出目录=build]
// 产出: <out>/AppIcon.iconset/*.png(全尺寸)+ <out>/icon-preview.png(浅/深底多尺寸预览)
// 随后 scripts/build-app.sh 会调 iconutil 打成 AppIcon.icns 放进 bundle。
//
// 设计:深蓝渐变圆角方 + 白色对话气泡,气泡内两条字幕条
//      —— 上条短而淡(英文原文)、下条长而实(中文译文),对应 app 的双语字幕。
import AppKit
import Foundation

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build"

/// 气泡内的图形:bars=两条字幕条 / cjk=「文」字 / mixed=淡原文条 +「文」
enum Style: String { case bars, cjk, mixed }
let style = Style(rawValue: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "bars") ?? .bars
let wantVariants = CommandLine.arguments.contains("--variants")

// MARK: - 绘制(尺寸无关,按 s 归一化)

func drawText(_ str: String, centeredIn rect: NSRect, size: CGFloat, color: NSColor) {
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: .bold),
        .foregroundColor: color,
    ]
    let a = NSAttributedString(string: str, attributes: attrs)
    let sz = a.size()
    a.draw(at: NSPoint(x: rect.midX - sz.width / 2, y: rect.midY - sz.height / 2))
}

func drawIcon(_ s: CGFloat, _ style: Style = style) {
    let inset = s * 0.075                       // macOS 图标惯例:留出四周透明边距
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237            // squircle 近似圆角

    let bg = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.30, green: 0.37, blue: 1.00, alpha: 1),   // 亮靛蓝
        NSColor(srgbRed: 0.05, green: 0.08, blue: 0.26, alpha: 1),   // 深夜蓝
    ])!
    gradient.draw(in: bg, angle: -62)

    // 对话气泡
    let bw = rect.width * 0.62
    let bh = rect.height * 0.44
    let bx = rect.midX - bw / 2
    let by = rect.midY - bh / 2 + rect.height * 0.05
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: bx, y: by, width: bw, height: bh),
                 xRadius: bh * 0.26, yRadius: bh * 0.26).fill()
    let tail = NSBezierPath()                   // 左下小尾巴
    tail.move(to: NSPoint(x: bx + bw * 0.16, y: by + bh * 0.03))
    tail.line(to: NSPoint(x: bx + bw * 0.36, y: by + bh * 0.03))
    tail.line(to: NSPoint(x: bx + bw * 0.20, y: by - rect.height * 0.11))
    tail.close()
    tail.fill()

    // 气泡内容
    let navy = NSColor(srgbRed: 0.08, green: 0.11, blue: 0.30, alpha: 1)
    let barH = bh * 0.155
    let padX = bw * 0.14
    let usable = bw - padX * 2
    let bubbleRect = NSRect(x: bx, y: by, width: bw, height: bh)

    func bar(y: CGFloat, widthRatio: CGFloat, alpha: CGFloat) {
        navy.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: NSRect(x: bx + padX, y: y, width: usable * widthRatio, height: barH),
                     xRadius: barH / 2, yRadius: barH / 2).fill()
    }

    switch style {
    case .bars:
        bar(y: by + bh * 0.57, widthRatio: 0.56, alpha: 0.40)   // 原文:短、淡
        bar(y: by + bh * 0.25, widthRatio: 0.92, alpha: 1.0)    // 译文:长、实
    case .cjk:
        drawText("文", centeredIn: bubbleRect, size: bh * 0.66, color: navy)
    case .mixed:
        bar(y: by + bh * 0.70, widthRatio: 0.62, alpha: 0.38)   // 上方淡条 = 英文原文
        drawText("文", centeredIn: NSRect(x: bx, y: by + bh * 0.02, width: bw, height: bh * 0.62),
                 size: bh * 0.50, color: navy)                  // 下方「文」= 中文译文
    }
}

// MARK: - 渲染

func makeRep(_ px: Int, _ st: Style = style) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawIcon(CGFloat(px), st)                   // 每个尺寸独立绘制,而非缩放,小图更清晰
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func pngData(_ rep: NSBitmapImageRep) -> Data {
    rep.representation(using: .png, properties: [:])!
}

func image(_ px: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.addRepresentation(makeRep(px))
    return img
}

/// 浅底/深底两行、多尺寸并排,用于肉眼检查小尺寸下是否还认得出。
func previewSheet() -> NSBitmapImageRep {
    let sizes = [256, 128, 64, 32, 16]
    let pad: CGFloat = 28
    let w = pad + sizes.reduce(CGFloat(0)) { $0 + CGFloat($1) + pad }
    let rowH: CGFloat = 256 + pad * 2
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(rowH * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = NSSize(width: w, height: rowH * 2)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1).setFill()
    NSRect(x: 0, y: rowH, width: w, height: rowH).fill()
    NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: w, height: rowH).fill()
    var x = pad
    for s in sizes {
        let img = image(s)
        img.draw(in: NSRect(x: x, y: rowH + pad, width: CGFloat(s), height: CGFloat(s)))
        img.draw(in: NSRect(x: x, y: pad, width: CGFloat(s), height: CGFloat(s)))
        x += CGFloat(s) + pad
    }
    NSGraphicsContext.restoreGraphicsState()
    return out
}

/// 三种风格 × 大/小尺寸并排,用于挑选。
func variantsSheet() -> NSBitmapImageRep {
    let styles: [Style] = [.bars, .cjk, .mixed]
    let big = 256, small = 32
    let pad: CGFloat = 34
    let colW = CGFloat(big) + pad
    let w = pad + colW * CGFloat(styles.count)
    let h = pad * 3 + CGFloat(big) + CGFloat(small) + 34
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(w), pixelsHigh: Int(h),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    NSColor(srgbRed: 0.95, green: 0.95, blue: 0.97, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: w, height: h).fill()
    for (i, st) in styles.enumerated() {
        let x = pad + colW * CGFloat(i)
        let bigImg = NSImage(size: NSSize(width: big, height: big))
        bigImg.addRepresentation(makeRep(big, st))
        bigImg.draw(in: NSRect(x: x, y: h - pad - CGFloat(big), width: CGFloat(big), height: CGFloat(big)))
        let smallImg = NSImage(size: NSSize(width: small, height: small))
        smallImg.addRepresentation(makeRep(small, st))
        smallImg.draw(in: NSRect(x: x + CGFloat(big) / 2 - CGFloat(small) / 2,
                                 y: h - pad * 2 - CGFloat(big) - CGFloat(small),
                                 width: CGFloat(small), height: CGFloat(small)))
        drawText(st.rawValue, centeredIn: NSRect(x: x, y: 12, width: CGFloat(big), height: 30),
                 size: 20, color: NSColor(srgbRed: 0.2, green: 0.2, blue: 0.25, alpha: 1))
    }
    NSGraphicsContext.restoreGraphicsState()
    return out
}

// MARK: - 输出

let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

if wantVariants {
    let p = "\(outDir)/icon-variants.png"
    try pngData(variantsSheet()).write(to: URL(fileURLWithPath: p))
    print("variants: \(p)")
    exit(0)
}

let iconset = "\(outDir)/AppIcon.iconset"
try? fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

let entries: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in entries {
    let url = URL(fileURLWithPath: "\(iconset)/\(name).png")
    try pngData(makeRep(px)).write(to: url)
}
let previewPath = "\(outDir)/icon-preview.png"
try pngData(previewSheet()).write(to: URL(fileURLWithPath: previewPath))

print("iconset: \(iconset) (\(entries.count) png)")
print("preview: \(previewPath)")
