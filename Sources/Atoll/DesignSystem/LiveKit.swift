import SwiftUI

// The live kit: the pieces every glanceable surface in the island is built from. One figure you read at a glance,
// one picture of it in the activity's own colour (an arc, bars, a track), quiet words, and tinted actions. The colour
// belongs to what's happening (orange for focus, green for a call, the album's own for music), never decoration.
// Everything animates by springs from `Motion`, only when its value changes, so nothing here costs a frame at rest.

// MARK: - The figure

/// A big number read at a glance, with its unit small beside it on the same baseline: "25:00", "92 %", "12 min".
struct LiveFigure: View {
    let value: String
    var unit: String? = nil
    var size: CGFloat = 40
    var tint: Color = DS.Ink.primary
    /// Counting down rolls digits the other way.
    var countsDown = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: size * 0.06) {
            Text(value)
                .font(.system(size: size, weight: .semibold, design: .rounded).monospacedDigit())
                .tracking(-size * 0.025)
                .foregroundStyle(tint)
                .contentTransition(.numericText(countsDown: countsDown))
            if let unit {
                Text(unit)
                    .font(.system(size: max(11, size * 0.36), weight: .semibold, design: .rounded))
                    .foregroundStyle(DS.Ink.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .accessibilityElement(children: .combine)
    }
}

/// Small capitals in the activity's colour, with an optional live dot: "FOCUS", "● ON A CALL".
struct LiveTag: View {
    let text: String
    var tint: Color
    var dot = false

    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(tint).frame(width: 5, height: 5) }
            Text(text.uppercased())
                .font(DS.Kit.eyebrow)
                .tracking(DS.Kit.eyebrowTracking)
                .foregroundStyle(tint)
                .lineLimit(1)
        }
    }
}

// MARK: - Pictures of the figure

/// A gauge on a three-quarter arc, open at the foot like a dial: the value sweeps in the tint over a dim track.
/// Optional content sits in the middle (a symbol, a small figure).
struct ArcGauge<Center: View>: View {
    /// 0…1.
    var value: Double
    var tint: Color
    var lineWidth: CGFloat = 6
    /// How much of the circle the dial spans.
    var sweep: Double = 0.75
    @ViewBuilder var center: () -> Center

    var body: some View {
        // A trimmed circle starts at 3 o'clock and runs clockwise. A dial turns so its gap is centred on 6 o'clock;
        // a full ring starts at 12, like a watch.
        let turn = sweep >= 1 ? -90 : 90 + (1 - sweep) * 180
        ZStack {
            Group {
                Circle()
                    .trim(from: 0, to: sweep)
                    .stroke(tint.opacity(0.2), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                Circle()
                    .trim(from: 0, to: sweep * min(1, max(0, value)))
                    .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .animation(Access.reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.86), value: value)
            }
            .rotationEffect(.degrees(turn))
            center()
        }
        .padding(lineWidth / 2)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

extension ArcGauge where Center == EmptyView {
    init(value: Double, tint: Color, lineWidth: CGFloat = 6, sweep: Double = 0.75) {
        self.init(value: value, tint: tint, lineWidth: lineWidth, sweep: sweep) { EmptyView() }
    }
}

/// A row of capsule bars: an hour-by-hour picture (focus through the day, a forecast, levels). The bar at `highlight`
/// is drawn in full colour and the rest dimmer; bars rise into place once, the first time they're shown.
struct BarSpark: View {
    /// 0…1 each.
    var values: [Double]
    var tint: Color
    var highlight: Int? = nil
    var spacing: CGFloat = 3
    /// The widest a bar gets.
    var maxBar: CGFloat = 6
    @State private var risen = RenderMode.snapshot || Access.reduceMotion

    var body: some View {
        GeometryReader { geo in
            let n = max(1, values.count)
            // Slim bars, spread across the width: the gaps carry the rhythm, not fat columns.
            let w = min(maxBar, max(2, (geo.size.width - spacing * CGFloat(n - 1)) / CGFloat(n)))
            let gap = n > 1 ? (geo.size.width - w * CGFloat(n)) / CGFloat(n - 1) : 0
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(values.indices, id: \.self) { i in
                    let v = min(1, max(0, values[i]))
                    Capsule()
                        .fill(highlight == nil || highlight == i ? tint : tint.opacity(0.5))
                        .frame(width: w, height: max(w, geo.size.height * (risen ? max(v, 0.04) : 0.04)))
                        .animation(.spring(response: 0.5, dampingFraction: 0.8).delay(Double(i) * 0.012), value: risen)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
        }
        .onAppear { if !risen { risen = true } }
        .accessibilityHidden(true)
    }
}

/// A progress track with what's done on the left and what's left on the right: "12:40 ━━━━──── −2:25".
struct LiveTrack: View {
    /// 0…1.
    var fraction: Double
    var tint: Color
    var leading: String? = nil
    var trailing: String? = nil
    var height: CGFloat = 5

    var body: some View {
        HStack(spacing: 10) {
            if let leading { Text(leading).font(DS.Kit.meta).foregroundStyle(DS.Ink.secondary).fixedSize() }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.14))
                    Capsule().fill(tint)
                        .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
                        .animation(Access.reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.9), value: fraction)
                }
            }
            .frame(height: height)
            if let trailing { Text(trailing).font(DS.Kit.meta).foregroundStyle(DS.Ink.secondary).fixedSize() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
    }
}

// MARK: - Actions and light

/// A tinted capsule action: quiet (the tint at low strength, its label in the tint) or prominent (filled).
struct TintPill: View {
    let title: String
    var symbol: String? = nil
    var tint: Color
    var prominent = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.system(size: 12, weight: .bold)) }
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            .foregroundStyle(prominent ? Color.black : tint)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(Capsule().fill(prominent ? tint : tint.opacity(hover ? 0.3 : 0.2)))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityLabel(title)
    }
}

/// The activity's colour as light inside the island, rising from one corner: what makes a card feel lit by what's
/// in it rather than painted.
struct TintGlow: View {
    var tint: Color
    var origin: UnitPoint = UnitPoint(x: 0.12, y: 1.05)
    var strength: Double = 1

    var body: some View {
        RadialGradient(colors: [tint.opacity(0.34 * strength), tint.opacity(0.08 * strength), .clear],
                       center: origin, startRadius: 0, endRadius: 260)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
