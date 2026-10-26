import SwiftUI
import AppKit

/// Mac Flow's mark and wordmark, drawn from the same geometry as the brand kit (`scripts/make_brand.swift`):
/// a stadium (the island, 3.156 : 1) with a four-point star cut through it — short sharp vertical points, horizontal
/// points that stretch into hairlines. The star on its own is Flow, the assistant.
enum Brand {
    static let aspect: CGFloat = 3.156
    /// "Mac" — near-black ink.
    static let ink = Color(red: 0x0A / 255, green: 0x0A / 255, blue: 0x0B / 255)
    /// "Flow" on light backgrounds.
    static let flow = Color(red: 0x63 / 255, green: 0x64 / 255, blue: 0x67 / 255)
    /// "Flow" on dark backgrounds.
    static let flowOnDark = Color(red: 0x8E / 255, green: 0x8E / 255, blue: 0x93 / 255)

    /// The star's curve, in fractions of the pill's height.
    fileprivate static let halfHeight: CGFloat = 0.3828
    fileprivate static let halfWidth: CGFloat = 0.7266
    fileprivate static let pull: CGFloat = 0.0156
    fileprivate static let reach: CGFloat = 0.3203

    /// The star path for a pill of height `h`, centred at `c` (y down).
    static func starPath(center c: CGPoint, h: CGFloat) -> Path {
        let v = halfHeight * h, w = halfWidth * h, pull = pull * h, reach = reach * h
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - v))
        p.addCurve(to: CGPoint(x: c.x + w, y: c.y), control1: CGPoint(x: c.x, y: c.y - pull), control2: CGPoint(x: c.x + reach, y: c.y))
        p.addCurve(to: CGPoint(x: c.x, y: c.y + v), control1: CGPoint(x: c.x + reach, y: c.y), control2: CGPoint(x: c.x, y: c.y + pull))
        p.addCurve(to: CGPoint(x: c.x - w, y: c.y), control1: CGPoint(x: c.x, y: c.y + pull), control2: CGPoint(x: c.x - reach, y: c.y))
        p.addCurve(to: CGPoint(x: c.x, y: c.y - v), control1: CGPoint(x: c.x - reach, y: c.y), control2: CGPoint(x: c.x, y: c.y - pull))
        p.closeSubpath()
        return p
    }

    /// The menu bar's template image: the mark, sized for the status bar.
    static func menuBarImage() -> NSImage {
        let size = NSSize(width: 26, height: 16)
        let img = NSImage(size: size, flipped: true) { _ in
            let pillRect = CGRect(x: 1.5, y: (16 - 7.6) / 2, width: 23, height: 7.6)
            let path = CGMutablePath()
            path.addPath(CGPath(roundedRect: pillRect, cornerWidth: pillRect.height / 2, cornerHeight: pillRect.height / 2, transform: nil))
            // A slightly bolder star at this size, so the cut still reads at 7.6 pt.
            path.addPath(starPath(center: CGPoint(x: pillRect.midX, y: pillRect.midY), h: pillRect.height * 1.12).cgPath)
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath(using: .evenOdd)
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Mac Flow"
        return img
    }
}

/// The four-point star — Flow's symbol. Fills its frame (2 : 1 works best).
struct FlowStar: Shape {
    func path(in rect: CGRect) -> Path {
        // The star spans 2 × halfWidth by 2 × halfHeight of its pill height; fit that to the rect.
        let h = min(rect.width / (2 * Brand.halfWidth), rect.height / (2 * Brand.halfHeight))
        return Brand.starPath(center: CGPoint(x: rect.midX, y: rect.midY), h: h)
    }
}

/// Flow's glyph at text sizes: the star, a touch fuller so it holds its shape small.
struct FlowGlyph: View {
    var size: CGFloat = 12
    var color: Color = BrainStyle.tint

    var body: some View {
        FlowStar()
            .fill(color)
            .frame(width: size * 1.5, height: size * 0.95)
            .frame(width: size * 1.5, height: size)
            .accessibilityHidden(true)
    }
}

/// The mark: the pill with the star cut through.
struct FlowMark: View {
    var color: Color = Brand.ink

    var body: some View {
        GeometryReader { geo in
            let h = min(geo.size.height, geo.size.width / Brand.aspect)
            let rect = CGRect(x: (geo.size.width - h * Brand.aspect) / 2, y: (geo.size.height - h) / 2, width: h * Brand.aspect, height: h)
            Path { p in
                p.addRoundedRect(in: rect, cornerSize: CGSize(width: h / 2, height: h / 2))
                p.addPath(Brand.starPath(center: CGPoint(x: rect.midX, y: rect.midY), h: h))
            }
            .fill(color, style: FillStyle(eoFill: true))
        }
        .aspectRatio(Brand.aspect, contentMode: .fit)
        .accessibilityLabel("Mac Flow")
    }
}

/// "Mac Flow": Mac in ink, Flow in grey — adapting to light and dark.
struct Wordmark: View {
    var size: CGFloat = 22
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        (Text("Mac").foregroundColor(scheme == .dark ? .white : Brand.ink)
         + Text(" Flow").foregroundColor(scheme == .dark ? Brand.flowOnDark : Brand.flow))
            .font(.system(size: size, weight: .medium))
            .accessibilityLabel("Mac Flow")
    }
}

/// The primary logo: the mark over the wordmark.
struct FlowLogo: View {
    var markHeight: CGFloat = 28
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: markHeight * 0.52) {
            FlowMark(color: scheme == .dark ? .white : Brand.ink)
                .frame(height: markHeight)
            Wordmark(size: markHeight * 1.3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mac Flow")
    }
}
