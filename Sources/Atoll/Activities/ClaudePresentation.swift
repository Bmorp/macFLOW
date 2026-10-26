import SwiftUI

/// An eight-ray spark that turns slowly while Claude works. The turn is a Core Animation loop that runs
/// in the system's renderer, so an hour-long task costs Atoll nothing per frame.
struct ClaudeGlyph: View {
    var size: CGFloat
    var spinning: Bool
    var tint: Color = ClaudeSessions.tint
    @Environment(\.islandShowing) private var showing

    var body: some View {
        Group {
            if RenderMode.snapshot {
                Canvas { g, s in
                    g.stroke(SparkView.path(in: CGRect(origin: .zero, size: s)), with: .color(tint),
                             style: StrokeStyle(lineWidth: SparkView.lineWidth(for: s), lineCap: .round))
                }
            } else {
                SparkRepresentable(spinning: spinning && showing && !Access.reduceMotion, color: NSColor(tint))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct SparkRepresentable: NSViewRepresentable {
    let spinning: Bool
    let color: NSColor
    func makeNSView(context: Context) -> SparkView { SparkView() }
    func updateNSView(_ v: SparkView, context: Context) {
        if v.color != color { v.color = color }
        v.spinning = spinning
    }
}

final class SparkView: NSView {
    private let shape = CAShapeLayer()
    var spinning = false { didSet { if spinning != oldValue { updateSpin() } } }
    var color: NSColor = .orange { didSet { shape.strokeColor = color.cgColor } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shape.fillColor = nil
        shape.lineCap = .round
        shape.strokeColor = color.cgColor
        layer?.addSublayer(shape)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = bounds
        shape.path = Self.path(in: bounds).cgPath
        shape.lineWidth = Self.lineWidth(for: bounds.size)
        CATransaction.commit()
        updateSpin()
    }

    private func updateSpin() {
        if spinning {
            guard shape.animation(forKey: "spin") == nil else { return }
            let a = CABasicAnimation(keyPath: "transform.rotation.z")
            a.fromValue = 0
            a.toValue = -2 * Double.pi
            a.duration = 4.5
            a.repeatCount = .infinity
            a.isRemovedOnCompletion = false
            shape.add(a, forKey: "spin")
        } else {
            shape.removeAnimation(forKey: "spin")
        }
    }

    static func lineWidth(for size: CGSize) -> CGFloat { max(1.4, min(size.width, size.height) / 2 * 0.24) }

    static func path(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        var p = Path()
        for i in 0..<8 {
            let a = Double(i) * .pi / 4 + 0.35
            let length = i.isMultiple(of: 2) ? r * 0.82 : r * 0.55
            p.move(to: CGPoint(x: c.x + cos(a) * r * 0.16, y: c.y + sin(a) * r * 0.16))
            p.addLine(to: CGPoint(x: c.x + cos(a) * length, y: c.y + sin(a) * length))
        }
        return p
    }
}

enum ClaudePresentation {
    static let brand = ClaudeSessions.tint

    static func elapsed(_ since: Date, now: Date = Date()) -> String { max(0, now.timeIntervalSince(since)).clock }

    /// "10m", "1h 4m", "42s" — never a clock face, which reads as the time of day.
    static func short(_ since: Date, now: Date = Date()) -> String {
        let t = Int(max(0, now.timeIntervalSince(since)))
        if t < 60 { return "\(t)s" }
        let m = t / 60
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }

    /// The spark, turning while it works. The project's name lives in the open island, where it has room.
    struct Leading: View {
        @ObservedObject private var claude = ClaudeSessions.shared
        var body: some View {
            HStack {
                ClaudeGlyph(size: 16, spinning: claude.featured?.state == .working)
                Spacer(minLength: 0)
            }
            .padding(.leading, 12)
        }
    }

    /// Working: Claude's thinking dots and how long. Needs you: a breathing dot and the words.
    struct Trailing: View {
        @ObservedObject private var claude = ClaudeSessions.shared
        var body: some View {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if let s = claude.featured, s.state == .waiting {
                    LiveDot(color: brand, size: 6)
                    Text("Needs you")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(DS.Ink.primary)
                        .lineLimit(1)
                        .fixedSize()
                } else if let s = claude.featured {
                    ThinkingDots(size: 15, color: brand)
                    TimelineView(ElapsedSchedule(since: s.since)) { ctx in
                        Text(short(s.since, now: ctx.date))
                            .font(DS.Typeface.compact)
                            .foregroundStyle(DS.Ink.primary)
                            .contentTransition(.numericText())
                            .fixedSize()
                    }
                    if claude.working.count > 1 {
                        Text("+\(claude.working.count - 1)")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(DS.Ink.tertiary)
                    }
                }
            }
            .padding(.trailing, 8)
        }
    }

    struct Minimal: View {
        let diameter: CGFloat
        @ObservedObject private var claude = ClaudeSessions.shared
        var body: some View {
            ClaudeGlyph(size: diameter - 14, spinning: claude.featured?.state == .working)
        }
    }

    /// ✳ CLAUDE · ATOLL / Rebuild the notch island ···· 3:12  ↗
    struct Expanded: View {
        var model: IslandModel
        @ObservedObject private var claude = ClaudeSessions.shared
        @Environment(\.islandShowing) private var showing

        var body: some View {
            let s = claude.featured
            let waiting = s?.state == .waiting
            Instrument(notch: model.notch, width: model.expandedWidth) {
                HStack(spacing: 14) {
                    ClaudeGlyph(size: 26, spinning: s?.state == .working).islandReveal(0)
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow(text: eyebrow(s), dot: waiting ? brand : nil, tint: waiting ? brand : DS.Ink.tertiary)
                        Text(s?.name ?? "Claude").font(DS.Kit.title).foregroundStyle(DS.Ink.primary).lineLimit(1)
                    }
                    .islandReveal(0)
                    Spacer(minLength: 8)
                    if waiting {
                        Pill(title: "Open") {
                            ClaudeSessions.shared.open(s)
                            model.collapse()
                        }
                        .islandReveal(2)
                    } else {
                        if let s, s.state == .working {
                            TimelineView(PeriodicTimelineSchedule.seconds(showing)) { ctx in
                                Figure(value: elapsed(s.since, now: ctx.date), size: 28)
                            }
                            .islandReveal(1)
                        }
                        Ghost(symbol: "arrow.up.forward", label: "Open in Claude", size: 13, tint: DS.Ink.secondary) {
                            ClaudeSessions.shared.open(s)
                            model.collapse()
                        }
                        .islandReveal(2)
                    }
                }
            }
        }

        private func eyebrow(_ s: ClaudeSessions.Session?) -> String {
            guard let s else { return "Claude" }
            var parts = [s.state == .waiting ? "Needs you" : "Claude", s.folder]
            let others = claude.sessions.filter { $0.id != s.id && $0.state != .idle }.count
            if others > 0 { parts.append("+\(others) more") }
            return parts.joined(separator: " · ")
        }
    }
}

/// The spark on a soft tile — the row's visual.
struct ClaudeTile: View {
    var spinning: Bool
    var size: CGFloat = 44
    var badge: String?

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ClaudeGlyph(size: size * 0.5, spinning: spinning)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(ClaudeSessions.tint.opacity(0.18)))
            if let badge {
                Image(systemName: badge)
                    .font(.system(size: size * 0.22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .background(Circle().fill(badge == "checkmark" ? DS.Palette.green : ClaudeSessions.tint))
                    .overlay(Circle().stroke(Color.black, lineWidth: 2))
                    .offset(x: 3, y: 3)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The home's Claude strip: your recent sessions, each one click away.
struct ClaudeStrip: View {
    @ObservedObject private var claude = ClaudeSessions.shared
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                ClaudeGlyph(size: 13, spinning: !claude.working.isEmpty)
                Text("Claude").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Palette.secondary)
            }
            .fixedSize()
            .padding(.trailing, 2)
            // Two, with room for their names, and how many more — not three cut short.
            ForEach(claude.sessions.prefix(2)) { s in
                Button {
                    ClaudeSessions.shared.open(s)
                    onOpen()
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(s.state == .waiting ? ClaudeSessions.tint : s.state == .working ? DS.Palette.green : Color.white.opacity(0.3))
                            .frame(width: 7, height: 7)
                        Text(s.name).font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Palette.label).lineLimit(1)
                        Text(status(s)).font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(DS.Palette.secondary)
                            .fixedSize()
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    // The first takes what its name needs (up to a point); the second gets the rest.
                    .frame(minWidth: s.id == claude.sessions.first?.id ? nil : 110,
                           maxWidth: s.id == claude.sessions.first?.id ? 300 : .infinity, alignment: .leading)
                    .fixedSize(horizontal: s.id == claude.sessions.first?.id, vertical: false)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressStyle(scale: 0.96))
                .help("Open “\(s.name)” — \(s.folder)")
                .accessibilityLabel("\(s.name), \(status(s))")
            }
            if claude.sessions.count > 2 {
                Button {
                    ClaudeSessions.shared.open(nil)
                    onOpen()
                } label: {
                    Text("+\(claude.sessions.count - 2)")
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(DS.Palette.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                        .contentShape(Capsule())
                }
                .buttonStyle(PressStyle(scale: 0.96))
                .fixedSize()
                .help("\(claude.sessions.count - 2) more Claude sessions")
                .accessibilityLabel("\(claude.sessions.count - 2) more Claude sessions")
            }
        }
    }

    private func status(_ s: ClaudeSessions.Session) -> String {
        switch s.state {
        case .waiting: return "Needs you"
        case .working: return ClaudePresentation.elapsed(s.since)
        case .idle:
            let m = Int(Date().timeIntervalSince(s.since) / 60)
            return m < 1 ? "now" : m < 60 ? "\(m)m" : m < 1440 ? "\(m / 60)h" : "\(m / 1440)d"
        }
    }
}

/// Claude's answer, streaming in, inside the search panel.
struct ClaudeAnswerPanel: View {
    @ObservedObject private var ask = ClaudeAsk.shared
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ClaudeGlyph(size: 16, spinning: ask.phase == .checking || ask.phase == .thinking || ask.phase == .answering)
                Text(ask.question)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Palette.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                GlyphButton(symbol: "chevron.left", label: "Back to Results", size: 11, tint: DS.Palette.secondary, hit: 24, action: onBack)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            footer
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var content: some View {
        switch ask.phase {
        case .checking, .thinking:
            Text("Thinking…").font(.system(size: 14, weight: .medium)).foregroundStyle(DS.Palette.secondary)
        case .answering, .done:
            ScrollView(.vertical, showsIndicators: false) {
                Text(LocalizedStringKey(ask.answer))
                    .font(.system(size: 14))
                    .foregroundStyle(DS.Palette.label)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .signedOut:
            Text("Sign in to Claude once to get answers right here. Until then, your question opens in Claude.")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(DS.Palette.label)
                .fixedSize(horizontal: false, vertical: true)
        case .unavailable:
            Text("Claude Code isn’t on this Mac yet. Your question can open in Claude instead.")
                .font(.system(size: 14, weight: .medium)).foregroundStyle(DS.Palette.label)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(message).font(.system(size: 14, weight: .medium)).foregroundStyle(DS.Palette.label)
                .fixedSize(horizontal: false, vertical: true)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            switch ask.phase {
            case .signedOut:
                ProminentButton(title: "Sign In", tint: ClaudeSessions.tint) { ask.signIn() }
                SecondaryButton(title: "Ask in Claude") { ask.openInClaude() }
            case .unavailable, .failed:
                SecondaryButton(title: "Ask in Claude") { ask.openInClaude() }
            case .done:
                SecondaryButton(title: "Copy", symbol: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ask.answer, forType: .string)
                    Haptics.confirm()
                }
                SecondaryButton(title: "Continue in Claude") { ask.openInClaude() }
            default:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
        .frame(height: 30)
    }
}
