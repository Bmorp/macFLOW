import SwiftUI

// Prism's cards: the one surface Home's hero, Flow's suggestions and Flow's questions share.
//
// A dark glass slab on the island's black, lit from above. The light is a field of colour (a violet for Flow, an
// album's palette for music, an accent for a task) seen through Prism's fluted glass, so its top edge breaks into
// vertical strips; a hairline rim catches the same light. Text and controls sit above the glass, never under it.
//
// Reduce Transparency draws the strips shaded over the card's own colour instead of looking through to anything, and
// the slab is built so that look carries on its own: depth comes from the shading and the rim, not from refraction.

extension PrismStyle {
    /// A card's glass: Flow's strips, a little wider so they read as flutes, and no sparks (those are for one moment a
    /// day, not for every card).
    static let card = PrismStyle(pitch: 4, lens: 0.7, magnify: 1.5, depth: 8, disperse: 0.4, specular: 0.42, sparks: 0)
}

/// The glass: slab, fluted light and rim, in the shape of a rounded rectangle. Fill the card's frame with it
/// (`.background(PrismSlab(...))`).
struct PrismSlab: View {
    /// The light's colour. Flow's violet is for Flow; a hero takes its own (task accent, event colour, album).
    var tint: Color = BrainStyle.tint
    var corner: CGFloat = 20
    /// 0…1.3: how bright the top light is.
    var lit: Double = 1
    /// What the light shows through: nil is a soft pool of `tint`; an image (an album's colour field) replaces it.
    var field: NSImage? = nil
    var style: PrismStyle = .card
    @ObservedObject private var conditions = PrismConditions.shared

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        let flat = conditions.current.reduceTransparency
        let contrast = Access.increaseContrast
        ZStack {
            // Dark glass: it darkens whatever light is behind it (the island's ambient colour), then a hair of white at the
            // top settles into the black below.
            shape.fill(Color.black.opacity(0.42))
            shape.fill(LinearGradient(colors: [Color.white.opacity(0.07), Color.white.opacity(0.015)], startPoint: .top, endPoint: .bottom))
            light(flat: flat)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.55), location: 0.4),
                                             .init(color: .clear, location: 0.95)], startPoint: .top, endPoint: .bottom))
                .clipShape(shape)
            // The rim: the top edge catches the light, the foot almost none.
            shape.strokeBorder(LinearGradient(colors: [Color.white.opacity(contrast ? 0.5 : 0.3), tint.opacity(0.14), Color.white.opacity(contrast ? 0.22 : 0.06)],
                                              startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The light field, through the glass. Without a field it's two overlapping washes, so the strips have something
    /// that changes across the card to bend.
    @ViewBuilder private func light(flat: Bool) -> some View {
        let s = lit * (flat ? 1.15 : 1)
        Group {
            if let field {
                Image(nsImage: field).resizable().interpolation(.high).saturation(1.1)
                    .opacity(0.5 * min(1.2, s))
            } else {
                ZStack {
                    LinearGradient(colors: [tint.opacity(0.4 * s), tint.opacity(0.09 * s), .clear], startPoint: .top, endPoint: .bottom)
                    RadialGradient(colors: [Color.white.opacity(0.3 * s), .clear], center: UnitPoint(x: 0.14, y: -0.05), startRadius: 0, endRadius: 240)
                    RadialGradient(colors: [tint.opacity(0.34 * s), .clear], center: UnitPoint(x: 0.92, y: 0.1), startRadius: 0, endRadius: 190)
                }
            }
        }
        .prism(style)
    }
}

/// A card: content on the glass.
struct PrismCard<Content: View>: View {
    var tint: Color = BrainStyle.tint
    var corner: CGFloat = 20
    var lit: Double = 1
    var field: NSImage? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content.background(PrismSlab(tint: tint, corner: corner, lit: lit, field: field))
    }
}

// MARK: - Flow's ask

/// Flow's card: a suggestion or a question, in one composition. The seal and a violet eyebrow say who's speaking;
/// the title says what; the one-line **Why** says why now; then the way out: a primary action (or the answers to a
/// question) and a quiet secondary.
struct PrismAsk: View {
    struct Action {
        let title: String
        /// What VoiceOver says when it isn't the title ("Don’t ask again" for "Don’t ask").
        var label: String? = nil
        let run: () -> Void
    }

    /// "Flow suggests", "Flow asks".
    var eyebrow: String
    var title: String
    /// The Brain's one line: why this, why now.
    var why: String?
    /// How long it has waited ("12 min ago"); blank when it's new.
    var waited: String = ""
    /// Others waiting behind this one; with `onMore` the count opens them.
    var more = 0
    var onMore: (() -> Void)?
    /// A suggestion's action. Questions use `options` instead.
    var primary: Action?
    var options: [Action] = []
    /// "Not now" / "Don't ask again".
    var secondary: Action?
    /// The glass's width of padding on every side.
    var padding: CGFloat = 12

    var body: some View {
        PrismCard(tint: BrainStyle.tint, corner: 20) {
            HStack(alignment: .top, spacing: 12) {
                FlowSeal(size: 30)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(eyebrow.uppercased())
                            .font(DS.Kit.eyebrow).tracking(DS.Kit.eyebrowTracking)
                            .foregroundStyle(BrainStyle.tint)
                        if !waited.isEmpty { Text(waited).font(DS.Kit.eyebrow).foregroundStyle(DS.Ink.tertiary) }
                        Spacer(minLength: 0)
                        if more > 0 { moreChip }
                    }
                    Text(title)
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.Ink.primary)
                        .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                    if let why, !why.isEmpty {
                        (Text("Why  ").font(.system(size: 11, weight: .semibold)).foregroundColor(DS.Ink.tertiary)
                         + Text(why).font(.system(size: 12, weight: .medium)).foregroundColor(DS.Ink.secondary))
                            .lineLimit(1).padding(.top, 2)
                            .accessibilityLabel("Why: \(why)")
                    }
                    if primary != nil || !options.isEmpty || secondary != nil {
                        HStack(spacing: 8) {
                            if let primary { Pill(title: primary.title, action: primary.run) }
                            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                                FlowOptionButton(title: o.title, action: o.run)
                            }
                            if let secondary { PrismQuiet(title: secondary.title, label: secondary.label, action: secondary.run) }
                        }
                        .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(padding)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(eyebrow)
    }
}

extension PrismAsk {
    /// "+2": how many more are waiting behind this one.
    @ViewBuilder fileprivate var moreChip: some View {
        let chip = Text("+\(more)")
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .foregroundStyle(BrainStyle.tint)
            .padding(.horizontal, 6).frame(height: 17)
            .background(Capsule().fill(BrainStyle.tint.opacity(0.18)))
        if let onMore {
            Button(action: onMore) { chip.contentShape(Capsule()) }
                .buttonStyle(PressStyle(scale: 0.94))
                .accessibilityLabel("\(more) more waiting. Show all")
        } else {
            chip.accessibilityLabel("\(more) more waiting")
        }
    }
}

/// A waiting item from Flow's inbox on the Prism card, with its answers wired up: a suggestion's action runs and the
/// suggestion leaves the inbox; a question's answers are recorded. After an action that takes you somewhere else the
/// caller closes the island (`onLeave`).
struct FlowAskCard: View {
    let item: FlowInbox.Item
    var more = 0
    var onMore: (() -> Void)?
    var onLeave: () -> Void = {}

    var body: some View {
        switch item.body {
        case .suggestion(let s):
            PrismAsk(eyebrow: "Flow suggests", title: s.title, why: s.detail, waited: Self.waited(item), more: more, onMore: onMore,
                     primary: .init(title: s.actionTitle) {
                FlowInbox.shared.accept(s)
                // Flow's own places (the conversation, the planner) open in the island; anything else leaves it.
                if s.action != .none, !FlowInboxCard.staysInIsland(s.action) { onLeave() }
            }, secondary: .init(title: "Not now") { FlowInbox.shared.dismiss(s) })
        case .question(let q):
            PrismAsk(eyebrow: "Flow asks", title: q.text, why: q.detail, waited: Self.waited(item), more: more, onMore: onMore,
                     options: q.options.map { o in .init(title: o.label) {
                FlowInbox.shared.answer(q, o)
                if q.key.hasPrefix("plan.checkin"), o.value == "replan" { onLeave() }
            } }, secondary: .init(title: "Don’t ask", label: "Don’t ask again") { FlowInbox.shared.skip(q) })
        }
    }

    /// How long it has waited, so a missed one reads as missed, not new.
    static func waited(_ item: FlowInbox.Item) -> String {
        let s = Date().timeIntervalSince(item.added)
        return s < 90 ? "" : s < 3600 ? "\(Int(s / 60)) min ago" : item.added.formatted(date: .omitted, time: .shortened)
    }
}

/// A secondary action: words, no chrome, brighter under the pointer.
struct PrismQuiet: View {
    let title: String
    var label: String? = nil
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hover ? DS.Ink.primary : DS.Ink.secondary)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.96))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityLabel(label ?? title)
    }
}
