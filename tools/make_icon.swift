import AppKit

/// アプリアイコンを描いて .iconset 用の PNG を書き出す．
/// 図柄は SpellBar のUIそのもの: 下線付きの変換対象語と，その下に並ぶ候補チップ．

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    let inset = s * 0.098
    let r = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    func x(_ f: CGFloat) -> CGFloat { r.minX + r.width * f }
    func y(_ f: CGFloat) -> CGFloat { r.minY + r.height * f }
    func w(_ f: CGFloat) -> CGFloat { r.width * f }
    func h(_ f: CGFloat) -> CGFloat { r.height * f }
    func pill(_ rect: CGRect, _ color: NSColor) {
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
    }

    // 背景: 角丸のダークな板
    let bg = NSBezierPath(roundedRect: r, xRadius: r.width * 0.2237, yRadius: r.width * 0.2237)
    NSGradient(colors: [NSColor(srgbRed: 0.25, green: 0.27, blue: 0.32, alpha: 1),
                        NSColor(srgbRed: 0.08, green: 0.09, blue: 0.12, alpha: 1)])!
        .draw(in: bg, angle: -90)

    let accent = NSColor(srgbRed: 0.29, green: 0.51, blue: 0.98, alpha: 1)

    // 小さいサイズでは要素を減らして潰れないようにする
    let detailed = px >= 64

    if detailed {
        // 変換対象の語（白い帯）と，その下線
        pill(CGRect(x: x(0.10), y: y(0.62), width: w(0.46), height: h(0.115)),
             NSColor(white: 0.97, alpha: 1))
        pill(CGRect(x: x(0.09), y: y(0.552), width: w(0.48), height: h(0.042)), accent)
    }

    // 候補チップの列
    let chipY = detailed ? y(0.255) : y(0.40)
    let chipH = detailed ? h(0.165) : h(0.20)
    let gap = w(0.05)
    var cx = x(0.10)
    let chips: [(CGFloat, NSColor)] = [
        (0.28, accent),
        (0.23, NSColor(white: 0.78, alpha: 1)),
        (0.19, NSColor(white: 0.55, alpha: 1)),
    ]
    for (fw, color) in chips {
        pill(CGRect(x: cx, y: chipY, width: w(fw), height: chipH), color)
        cx += w(fw) + gap
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// .icns が要求する解像度一式
let plan: [(Int, String)] = [
    (16, "icon_16x16.png"),    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in plan {
    try! draw(px).write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
print("wrote \(plan.count) png to \(outDir)")
