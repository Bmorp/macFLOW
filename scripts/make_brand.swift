// Generates the Mac Flow brand kit — vector (SVG, PDF) and raster (PNG) — from one definition of the mark.
// Usage: swift scripts/make_brand.swift [output-dir]   (default: brand/)
//
// The mark: a stadium (the island, 3.156 : 1) with a four-point star cut through it. The star's vertical points are
// short and sharp; its horizontal points stretch into hairlines — light escaping the island. Every measurement below
// is a fraction of the pill's height H, fitted to the reference artwork.
import AppKit
import CoreText

let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "brand")

// MARK: - Brand constants

enum Brand {
    static let ink = NSColor(srgbRed: 0x0A / 255, green: 0x0A / 255, blue: 0x0B / 255, alpha: 1)        // #0A0A0B
    static let flow = NSColor(srgbRed: 0x63 / 255, green: 0x64 / 255, blue: 0x67 / 255, alpha: 1)       // #636467
    static let paper = NSColor.white                                                                     // #FFFFFF
    static let night = NSColor(srgbRed: 0x0A / 255, green: 0x0A / 255, blue: 0x0B / 255, alpha: 1)      // #0A0A0B
    static let flowOnDark = NSColor(srgbRed: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255, alpha: 1) // #8E8E93

    static let aspect: CGFloat = 3.156          // pill width / height
    static let starHalfHeight: CGFloat = 0.3828 // vertical point, from centre
    static let starHalfWidth: CGFloat = 0.7266  // horizontal hairline point, from centre
    static let starPull: CGFloat = 0.0156       // control point beside the vertical points
    static let starReach: CGFloat = 0.3203      // control point along the horizontal axis
}

// MARK: - Geometry (y down, like SVG)

func pill(_ r: CGRect) -> CGPath {
    CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
}

/// The four-point star, centred at `c`, for a pill of height `h`.
func star(center c: CGPoint, h: CGFloat) -> CGPath {
    let v = Brand.starHalfHeight * h, w = Brand.starHalfWidth * h
    let pull = Brand.starPull * h, reach = Brand.starReach * h
    let p = CGMutablePath()
    p.move(to: CGPoint(x: c.x, y: c.y - v))
    p.addCurve(to: CGPoint(x: c.x + w, y: c.y), control1: CGPoint(x: c.x, y: c.y - pull), control2: CGPoint(x: c.x + reach, y: c.y))
    p.addCurve(to: CGPoint(x: c.x, y: c.y + v), control1: CGPoint(x: c.x + reach, y: c.y), control2: CGPoint(x: c.x, y: c.y + pull))
    p.addCurve(to: CGPoint(x: c.x - w, y: c.y), control1: CGPoint(x: c.x, y: c.y + pull), control2: CGPoint(x: c.x - reach, y: c.y))
    p.addCurve(to: CGPoint(x: c.x, y: c.y - v), control1: CGPoint(x: c.x - reach, y: c.y), control2: CGPoint(x: c.x, y: c.y - pull))
    p.closeSubpath()
    return p
}

/// The mark: the pill with the star cut out (even-odd).
func mark(in r: CGRect) -> CGPath {
    let p = CGMutablePath()
    p.addPath(pill(r))
    p.addPath(star(center: CGPoint(x: r.midX, y: r.midY), h: r.height))
    return p
}

/// Glyph outlines of a string in SF Pro (the system font), y down, baseline at y = 0, with each word's range.
func wordmarkOutlines(size: CGFloat, weight: NSFont.Weight) -> (mac: CGPath, flow: CGPath) {
    let font = NSFont.systemFont(ofSize: size, weight: weight) as CTFont
    let text = "Mac Flow"
    let attr = NSAttributedString(string: text, attributes: [.font: font])
    let line = CTLineCreateWithAttributedString(attr)
    let mac = CGMutablePath(), flow = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        var indices = [CFIndex](repeating: 0, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
        CTRunGetStringIndices(run, CFRange(location: 0, length: count), &indices)
        let runFont = (CTRunGetAttributes(run) as Dictionary)[kCTFontAttributeName] as! CTFont
        for i in 0..<count {
            var t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: positions[i].x, ty: -positions[i].y)
            guard let g = CTFontCreatePathForGlyph(runFont, glyphs[i], &t) else { continue }
            (indices[i] < 4 ? mac : flow).addPath(g)
        }
    }
    return (mac, flow)
}

// MARK: - Drawing

struct Shape {
    let path: CGPath
    let color: NSColor
    var evenOdd = false
}

struct Artwork {
    let name: String
    let size: CGSize
    var background: NSColor? = nil
    let shapes: [Shape]
}

func hex(_ c: NSColor) -> String {
    let s = c.usingColorSpace(.sRGB)!
    return String(format: "#%02X%02X%02X", Int(round(s.redComponent * 255)), Int(round(s.greenComponent * 255)), Int(round(s.blueComponent * 255)))
}

func svgPath(_ path: CGPath) -> String {
    var d = ""
    func f(_ v: CGFloat) -> String { String(format: "%.2f", v).replacingOccurrences(of: ".00", with: "") }
    path.applyWithBlock { el in
        let p = el.pointee.points
        switch el.pointee.type {
        case .moveToPoint: d += "M\(f(p[0].x)) \(f(p[0].y))"
        case .addLineToPoint: d += "L\(f(p[0].x)) \(f(p[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))"
        case .addCurveToPoint: d += "C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return d
}

func writeSVG(_ a: Artwork, to url: URL) {
    var s = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(Int(a.size.width))\" height=\"\(Int(a.size.height))\" viewBox=\"0 0 \(Int(a.size.width)) \(Int(a.size.height))\">\n"
    s += "  <title>Mac Flow — \(a.name)</title>\n"
    if let bg = a.background { s += "  <rect width=\"100%\" height=\"100%\" fill=\"\(hex(bg))\"/>\n" }
    for sh in a.shapes {
        s += "  <path fill=\"\(hex(sh.color))\"\(sh.evenOdd ? " fill-rule=\"evenodd\"" : "") d=\"\(svgPath(sh.path))\"/>\n"
    }
    s += "</svg>\n"
    try! s.write(to: url, atomically: true, encoding: .utf8)
}

func draw(_ a: Artwork, in ctx: CGContext, scale: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: 0, y: a.size.height * scale)
    ctx.scaleBy(x: scale, y: -scale)
    if let bg = a.background {
        ctx.setFillColor(bg.cgColor)
        ctx.fill(CGRect(origin: .zero, size: a.size))
    }
    for sh in a.shapes {
        ctx.addPath(sh.path)
        ctx.setFillColor(sh.color.cgColor)
        ctx.fillPath(using: sh.evenOdd ? .evenOdd : .winding)
    }
    ctx.restoreGState()
}

func writePNG(_ a: Artwork, width: Int, to url: URL) {
    let scale = CGFloat(width) / a.size.width
    let w = width, h = Int((a.size.height * scale).rounded())
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    draw(a, in: ctx, scale: scale)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

func writePDF(_ a: Artwork, to url: URL) {
    var box = CGRect(origin: .zero, size: a.size)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    ctx.beginPDFPage(nil)
    draw(a, in: ctx, scale: 1)
    ctx.endPDFPage()
    ctx.closePDF()
}

// MARK: - Compositions (units: H = pill height = 128)

let H: CGFloat = 128
let W = (H * Brand.aspect).rounded()
let pad = H * 0.5   // clear space: half the pill's height on every side

func translated(_ p: CGPath, _ dx: CGFloat, _ dy: CGFloat, scale: CGFloat = 1) -> CGPath {
    var t = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: scale, y: scale)
    return p.copy(using: &t)!
}

/// The wordmark scaled so its cap height is `capHeight`, top-left at origin.
func wordmark(capHeight: CGFloat) -> (mac: CGPath, flow: CGPath, size: CGSize) {
    let raw = wordmarkOutlines(size: 200, weight: .medium)
    let union = CGMutablePath()
    union.addPath(raw.mac)
    union.addPath(raw.flow)
    let b = union.boundingBoxOfPath
    let s = capHeight / b.height
    func fit(_ p: CGPath) -> CGPath { translated(p, -b.minX * s, -b.minY * s, scale: s) }
    return (fit(raw.mac), fit(raw.flow), CGSize(width: b.width * s, height: b.height * s))
}

func artworks() -> [Artwork] {
    var list: [Artwork] = []
    let markRect = CGRect(x: pad, y: pad, width: W, height: H)
    let markSize = CGSize(width: W + pad * 2, height: H + pad * 2)

    for (suffix, color) in [("black", Brand.ink), ("white", NSColor.white)] {
        list.append(Artwork(name: "mark-\(suffix)", size: markSize, shapes: [Shape(path: mark(in: markRect), color: color, evenOdd: true)]))
    }
    // The star alone — Flow, the assistant.
    let starSize = CGSize(width: H * 1.6 + pad * 2, height: H * 0.8 + pad * 2)
    let starPath = star(center: CGPoint(x: starSize.width / 2, y: starSize.height / 2), h: H * 1.04)
    for (suffix, color) in [("black", Brand.ink), ("white", NSColor.white)] {
        list.append(Artwork(name: "star-\(suffix)", size: starSize, shapes: [Shape(path: starPath, color: color)]))
    }

    // Wordmark alone.
    let wm = wordmark(capHeight: H * 0.914)
    let wmSize = CGSize(width: wm.size.width + pad * 2, height: wm.size.height + pad * 2)
    for (suffix, mac, flow) in [("light", Brand.ink, Brand.flow), ("dark", NSColor.white, Brand.flowOnDark)] {
        list.append(Artwork(name: "wordmark-\(suffix)", size: wmSize,
                            shapes: [Shape(path: translated(wm.mac, pad, pad), color: mac), Shape(path: translated(wm.flow, pad, pad), color: flow)]))
    }

    // Stacked lockup (the primary logo): mark centred over the wordmark.
    let gap = H * 0.52
    let stackW = max(W, wm.size.width) + pad * 2
    let stackH = H + gap + wm.size.height + pad * 2
    let stackMark = mark(in: CGRect(x: (stackW - W) / 2, y: pad, width: W, height: H))
    let stackWM = (translated(wm.mac, (stackW - wm.size.width) / 2, pad + H + gap), translated(wm.flow, (stackW - wm.size.width) / 2, pad + H + gap))

    // Horizontal lockup: mark, then wordmark, centred on the pill.
    let hCap = H * 0.62
    let hwm = wordmark(capHeight: hCap)
    let hGap = H * 0.42
    let horW = W + hGap + hwm.size.width + pad * 2
    let horH = H + pad * 2
    let horMark = mark(in: CGRect(x: pad, y: pad, width: W, height: H))
    let horWM = (translated(hwm.mac, pad + W + hGap, pad + (H - hwm.size.height) / 2), translated(hwm.flow, pad + W + hGap, pad + (H - hwm.size.height) / 2))

    for (suffix, bg, ink, flow) in [("light", Optional<NSColor>.none, Brand.ink, Brand.flow), ("dark", Optional<NSColor>.none, NSColor.white, Brand.flowOnDark)] {
        list.append(Artwork(name: "logo-stacked-\(suffix)", size: CGSize(width: stackW, height: stackH), background: bg,
                            shapes: [Shape(path: stackMark, color: ink, evenOdd: true), Shape(path: stackWM.0, color: ink), Shape(path: stackWM.1, color: flow)]))
        list.append(Artwork(name: "logo-horizontal-\(suffix)", size: CGSize(width: horW, height: horH), background: bg,
                            shapes: [Shape(path: horMark, color: ink, evenOdd: true), Shape(path: horWM.0, color: ink), Shape(path: horWM.1, color: flow)]))
    }

    // Avatars (square, for profiles and social): the mark on paper and on night.
    let av: CGFloat = 1024
    let avW = av * 0.7, avH = avW / Brand.aspect
    let avMark = mark(in: CGRect(x: (av - avW) / 2, y: (av - avH) / 2, width: avW, height: avH))
    list.append(Artwork(name: "avatar-light", size: CGSize(width: av, height: av), background: Brand.paper, shapes: [Shape(path: avMark, color: Brand.ink, evenOdd: true)]))
    list.append(Artwork(name: "avatar-dark", size: CGSize(width: av, height: av), background: Brand.night, shapes: [Shape(path: avMark, color: .white, evenOdd: true)]))
    return list
}

// MARK: - Output

let fm = FileManager.default
for sub in ["svg", "pdf", "png"] { try? fm.createDirectory(at: outDir.appendingPathComponent(sub), withIntermediateDirectories: true) }

for a in artworks() {
    writeSVG(a, to: outDir.appendingPathComponent("svg/macflow-\(a.name).svg"))
    writePDF(a, to: outDir.appendingPathComponent("pdf/macflow-\(a.name).pdf"))
    let widths: [Int] = a.name.hasPrefix("avatar") ? [1024, 512, 256] : [Int(a.size.width * 2), Int(a.size.width * 4), Int(a.size.width * 8)]
    for w in widths {
        writePNG(a, width: w, to: outDir.appendingPathComponent("png/macflow-\(a.name)-\(w)px.png"))
    }
}

// The app icon's glass layer (Icon Composer): the mark centred on a 1024 canvas, black, star cut through.
let iconW: CGFloat = 660, iconH = iconW / Brand.aspect
let iconMark = mark(in: CGRect(x: (1024 - iconW) / 2, y: (1024 - iconH) / 2, width: iconW, height: iconH))
writeSVG(Artwork(name: "icon-layer", size: CGSize(width: 1024, height: 1024), shapes: [Shape(path: iconMark, color: Brand.ink, evenOdd: true)]),
         to: outDir.appendingPathComponent("svg/macflow-icon-layer.svg"))
print("brand kit → \(outDir.path)")
