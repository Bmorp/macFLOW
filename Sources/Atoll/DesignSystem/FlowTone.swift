import SwiftUI

/// The workspace palette and geometry: obsidian surfaces in three steps, two inks, one accent that means something.
/// Spacing is an 8-point scale (with a 4 for hairline gaps); corners come from one scale so nested shapes stay concentric.
enum FlowTone {
    // Surfaces
    static let base = Color(red: 0x09 / 255, green: 0x0A / 255, blue: 0x0D / 255)        // #090A0D
    static let elevated = Color(red: 0x17 / 255, green: 0x19 / 255, blue: 0x1E / 255)    // #17191E
    static let raised = Color(red: 0x29 / 255, green: 0x2C / 255, blue: 0x33 / 255)      // #292C33
    // Inks
    static let ink = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255)         // #F5F5F7
    static let inkSecondary = Color(red: 0x92 / 255, green: 0x97 / 255, blue: 0xA2 / 255) // #9297A2
    static var inkTertiary: Color { inkSecondary.opacity(Access.increaseContrast ? 0.95 : 0.7) }
    // Meaning
    static let accent = Color(red: 0x70 / 255, green: 0xA7 / 255, blue: 0xFF / 255)      // #70A7FF
    static let good = Color(red: 0.42, green: 0.82, blue: 0.55)
    static let caution = Color(red: 0.96, green: 0.74, blue: 0.36)
    static let bad = Color(red: 0.96, green: 0.45, blue: 0.42)
    static var hairline: Color { Color.white.opacity(Access.increaseContrast ? 0.18 : 0.07) }

    /// 4 · 8 · 16 · 24 · 32
    enum Space {
        static let hair: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    /// 6 · 10 · 14 · 20
    enum Radius {
        static let chip: CGFloat = 6
        static let control: CGFloat = 10
        static let tile: CGFloat = 14
        static let panel: CGFloat = 20
    }

    static let mono = Font.system(size: 11.5, weight: .medium, design: .monospaced)
    static let label = Font.system(size: 12, weight: .medium)
    static let body = Font.system(size: 13, weight: .regular)
    static let title = Font.system(size: 13, weight: .semibold)
    static let heading = Font.system(size: 15, weight: .semibold)
}

/// A workspace tile: an elevated surface with a hairline, for one subject.
struct ToneTile<Content: View>: View {
    var padding: CGFloat = FlowTone.Space.m
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: FlowTone.Radius.tile, style: .continuous).fill(FlowTone.elevated))
            .overlay(RoundedRectangle(cornerRadius: FlowTone.Radius.tile, style: .continuous).strokeBorder(FlowTone.hairline, lineWidth: 0.5))
    }
}

/// A tile's heading: a small symbol and a quiet label, with an optional value on the right.
struct ToneHeader: View {
    let symbol: String
    let title: String
    var trailing: String? = nil
    var tint: Color = FlowTone.inkSecondary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            Text(title).font(FlowTone.label).foregroundStyle(FlowTone.inkSecondary).lineLimit(1).layoutPriority(1)
            Spacer(minLength: 4)
            if let trailing { Text(trailing).font(FlowTone.mono).foregroundStyle(FlowTone.inkTertiary).lineLimit(1).truncationMode(.head) }
        }
    }
}
