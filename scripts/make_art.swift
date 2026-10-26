// Renders the DMG window background (640 × 400 pt, @1x and @2x).
// The app icon itself is an Icon Composer document compiled by actool — see Resources/AppIcon.icon.
// Usage: swift make_art.swift <output-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

/// The island silhouette hanging from the top edge (y up; `top` is the top edge).
func island(centerX: CGFloat, top: CGFloat, width: CGFloat, height: CGFloat, shoulder s: CGFloat, corner c: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let x0 = centerX - width / 2, x1 = centerX + width / 2, bottom = top - height
    let r = c * 1.25, k: CGFloat = 0.32
    p.move(to: CGPoint(x: x0, y: top))
    p.addCurve(to: CGPoint(x: x0 + s, y: top - s), control1: CGPoint(x: x0 + s * 0.62, y: top), control2: CGPoint(x: x0 + s, y: top - s * 0.38))
    p.addLine(to: CGPoint(x: x0 + s, y: bottom + r))
    p.addCurve(to: CGPoint(x: x0 + s + r, y: bottom), control1: CGPoint(x: x0 + s, y: bottom + r * k), control2: CGPoint(x: x0 + s + r * k, y: bottom))
    p.addLine(to: CGPoint(x: x1 - s - r, y: bottom))
    p.addCurve(to: CGPoint(x: x1 - s, y: bottom + r), control1: CGPoint(x: x1 - s - r * k, y: bottom), control2: CGPoint(x: x1 - s, y: bottom + r * k))
    p.addLine(to: CGPoint(x: x1 - s, y: top - s))
    p.addCurve(to: CGPoint(x: x1, y: top), control1: CGPoint(x: x1 - s, y: top - s * 0.38), control2: CGPoint(x: x1 - s * 0.62, y: top))
    p.closeSubpath()
    return p
}

/// The Mac Flow star (y up; same geometry as the brand kit).
func flowStar(center c: CGPoint, h: CGFloat) -> CGPath {
    let v = 0.3828 * h, w = 0.7266 * h, pull = 0.0156 * h, reach = 0.3203 * h
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y + v))
    p.addCurve(to: CGPoint(x: c.x + w, y: c.y), control1: CGPoint(x: c.x, y: c.y + pull), control2: CGPoint(x: c.x + reach, y: c.y))
    p.addCurve(to: CGPoint(x: c.x, y: c.y - v), control1: CGPoint(x: c.x + reach, y: c.y), control2: CGPoint(x: c.x, y: c.y - pull))
    p.addCurve(to: CGPoint(x: c.x - w, y: c.y), control1: CGPoint(x: c.x, y: c.y - pull), control2: CGPoint(x: c.x - reach, y: c.y))
    p.addCurve(to: CGPoint(x: c.x, y: c.y + v), control1: CGPoint(x: c.x - reach, y: c.y), control2: CGPoint(x: c.x, y: c.y + pull))
    p.closeSubpath()
    return p
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color c: NSColor, in rect: CGRect) {
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    para.lineBreakMode = .byWordWrapping
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: c, .paragraphStyle: para])
        .draw(with: rect, options: [.usesLineFragmentOrigin])
}

func render(scale: CGFloat, to url: URL) {
    let w: CGFloat = 640, h: CGFloat = 400
    let ctx = CGContext(data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)

    // Quiet light ground, like Apple's installer windows, so Finder's dark labels stay legible.
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(0xFCFCFE), color(0xF0F0F5)] as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0), options: [])

    // The Mac Flow logo — the mark (pill with the star cut through) over the wordmark — once, at the top.
    let markH: CGFloat = 30, markW = markH * 3.156
    let markRect = CGRect(x: (w - markW) / 2, y: h - 40 - markH, width: markW, height: markH)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: markRect, cornerWidth: markH / 2, cornerHeight: markH / 2, transform: nil))
    ctx.addPath(flowStar(center: CGPoint(x: markRect.midX, y: markRect.midY), h: markH))
    ctx.setFillColor(color(0x0A0A0B))
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let word = NSMutableAttributedString(string: "Mac", attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .medium), .foregroundColor: NSColor(srgbRed: 0x0A / 255, green: 0x0A / 255, blue: 0x0B / 255, alpha: 1)])
    word.append(NSAttributedString(string: " Flow", attributes: [.font: NSFont.systemFont(ofSize: 26, weight: .medium), .foregroundColor: NSColor(srgbRed: 0x63 / 255, green: 0x64 / 255, blue: 0x67 / 255, alpha: 1)]))
    let ws = word.size()
    word.draw(at: CGPoint(x: (w - ws.width) / 2, y: markRect.minY - 16 - ws.height))

    // Arrow from the app (x 170) to Applications (x 470); icon centres sit 190 pt from the top.
    let y = h - 196
    ctx.setStrokeColor(color(0xC7C7CC))
    ctx.setLineWidth(3)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 262, y: y))
    ctx.addLine(to: CGPoint(x: 378, y: y))
    ctx.move(to: CGPoint(x: 364, y: y + 12))
    ctx.addLine(to: CGPoint(x: 378, y: y))
    ctx.addLine(to: CGPoint(x: 364, y: y - 12))
    ctx.strokePath()

    let secondary = NSColor(srgbRed: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255, alpha: 1)
    let tertiary = NSColor(srgbRed: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255, alpha: 1)
    text("Drag Mac Flow to Applications to install it.", size: 13, weight: .medium, color: secondary,
         in: CGRect(x: 0, y: 78, width: w, height: 20))
    text("Opening it for the first time? If macOS says it can’t check Mac Flow, open System Settings › Privacy & Security and click Open Anyway.",
         size: 11, weight: .regular, color: tertiary, in: CGRect(x: 90, y: 28, width: w - 180, height: 32))
    NSGraphicsContext.restoreGraphicsState()

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    rep.size = NSSize(width: w, height: h)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

render(scale: 1, to: out.appendingPathComponent("dmg_bg.png"))
render(scale: 2, to: out.appendingPathComponent("dmg_bg@2x.png"))
print("art ok")
