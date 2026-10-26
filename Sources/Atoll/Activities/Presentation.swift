import SwiftUI

// MARK: - Choreography

private struct RevealClockKey: EnvironmentKey { static let defaultValue: Double? = nil }

private struct IslandShowingKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// False while a presentation is kept alive but out of sight (Home, between hovers): its clocks stop ticking.
    var islandShowing: Bool {
        get { self[IslandShowingKey.self] }
        set { self[IslandShowingKey.self] = newValue }
    }

    /// Debug renders set a fixed time (seconds since the presentation appeared) to draw any frame of a reveal.
    var revealClock: Double? {
        get { self[RevealClockKey.self] }
        set { self[RevealClockKey.self] = newValue }
    }
}

/// Content arrives with the shape: no blur, no fade. Kept as a named hook so every presentation
/// marks the same elements, and so the debug renders can still address them.
struct IslandReveal: ViewModifier {
    let index: Int
    func body(content: Content) -> some View { content }
}

extension View {
    func islandReveal(_ index: Int) -> some View { modifier(IslandReveal(index: index)) }
}

extension PeriodicTimelineSchedule {
    /// Once a second while on show; effectively never while hidden.
    static func seconds(_ showing: Bool) -> PeriodicTimelineSchedule {
        showing ? .periodic(from: .now, by: 1) : .periodic(from: .distantFuture, by: 3600)
    }
}

/// Updates for a short elapsed label ("42s", "12m", "1h 4m"): every second for the first minute, then only
/// when the minute turns — a long Claude task re-renders the compact island once a minute, not 60 times.
struct ElapsedSchedule: TimelineSchedule {
    let since: Date
    var showing = true

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> Entries {
        Entries(upcoming: startDate, since: since, showing: showing)
    }

    struct Entries: Sequence, IteratorProtocol {
        var upcoming: Date?
        let since: Date
        let showing: Bool

        mutating func next() -> Date? {
            guard let current = upcoming else { return nil }
            guard showing else {
                upcoming = nil
                return current
            }
            let elapsed = Swift.max(0, current.timeIntervalSince(since))
            let step: TimeInterval = elapsed < 59 ? 1 : 60
            // Land on the boundary where the label changes, not a fixed interval after now.
            upcoming = since.addingTimeInterval((floor(elapsed / step) + 1) * step)
            return current
        }
    }
}

// MARK: - Layouts

/// Compact presentation: two elements snug against the notch that read as one piece.
struct CompactLayout<Leading: View, Trailing: View>: View {
    let notch: CGSize
    let wing: CGFloat
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 0) {
            leading.frame(width: wing, height: notch.height).islandReveal(0)
            Spacer(minLength: 0)
            trailing.frame(width: wing, height: notch.height).islandReveal(1)
        }
        .padding(.horizontal, IslandModel.compactFlare)
        .frame(height: notch.height)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The one-row anatomy every open state shares: a 44-pt visual, two lines of text, then controls —
/// below the notch, inside the island's rounded body.
struct RowLayout<Leading: View, Center: View, Trailing: View>: View {
    let notch: CGSize
    let width: CGFloat
    var height: CGFloat = DS.Size.rowHeight
    @ViewBuilder var leading: Leading
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: notch.height)
            HStack(spacing: 12) {
                leading.islandReveal(0)
                center
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .islandReveal(1)
                trailing.islandReveal(2)
            }
            .padding(.horizontal, IslandModel.expandedFlare + DS.Island.rowLeading)
            .padding(.top, 4)
            .padding(.bottom, 14)
            .frame(height: height)
        }
        .frame(width: width, alignment: .top)
    }
}

/// Title and detail, the two lines of every row.
struct RowText: View {
    let title: String
    var detail: String?
    var detailTint: Color = DS.Palette.secondary
    var marquee = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if marquee {
                MarqueeText(text: title, font: .system(size: 15, weight: .semibold), color: DS.Palette.label)
            } else {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Palette.label)
                    .lineLimit(1)
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(detailTint)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A glyph on a soft tinted tile — the row's visual when there's no artwork.
struct RowTile: View {
    let symbol: String
    var tint: Color
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .symbolRenderingMode(.hierarchical)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(tint.opacity(0.18)))
            .accessibilityHidden(true)
    }
}

/// Rounded rectangle whose corner scales with its size, so a visual keeps its proportions while it grows.
struct ProportionalRoundedRect: Shape {
    var ratio: CGFloat
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * ratio, style: .continuous)
    }
}

/// Album art (or the playing app's icon) that fills whatever size it's given — it travels
/// from the compact wing into the open row as one object.
struct LeadArtwork: View {
    @ObservedObject private var media = NowPlayingModel.shared

    var body: some View {
        if media.mode == .app, let icon = media.otherApp?.icon {
            Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
        } else {
            ZStack {
                if let art = media.artwork {
                    Image(nsImage: art).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [media.accent, media.accent.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note").resizable().scaledToFit().padding(10).foregroundStyle(.white.opacity(0.9))
                        .scaleEffect(0.6)
                }
            }
            .clipShape(ProportionalRoundedRect(ratio: 0.23))
        }
    }
}

/// A calendar page: month in red over the day, as in Calendar.
struct DateTile: View {
    let date: Date
    var size: CGFloat = 44

    var body: some View {
        VStack(spacing: -2) {
            Text(date.formatted(.dateTime.month(.abbreviated)).uppercased())
                .font(.system(size: size * 0.21, weight: .bold))
                .foregroundStyle(Color(red: 0.98, green: 0.24, blue: 0.2))
            Text(date.formatted(.dateTime.day()))
                .font(.system(size: size * 0.47, weight: .semibold).monospacedDigit())
                .foregroundStyle(Color.black.opacity(0.88))
        }
        .frame(width: size, height: size)
        .background(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous).fill(Color.white))
        .accessibilityHidden(true)
    }
}

/// A round control: filled with its colour, with an optional progress ring around it.
struct RowDisc: View {
    let symbol: String
    let label: String
    var tint: Color = .white
    var fill: Double = 0.16
    var glyph: Color = .white
    var diameter: CGFloat = 36
    var progress: Double?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().fill(tint.opacity(hover ? fill + 0.08 : fill))
                if let progress {
                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(0.001, min(progress, 1)))
                        .stroke(tint == .white ? Color.white : tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.5), value: progress)
                }
                Image(systemName: symbol)
                    .font(.system(size: diameter * 0.38, weight: .bold))
                    .foregroundStyle(glyph)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: diameter, height: diameter)
            .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help(label)
        .accessibilityLabel(label)
    }
}

// MARK: - Dispatch

struct ActivityCompact: View {
    let kind: ActivityKind
    let model: IslandModel
    let ns: Namespace.ID
    @ObservedObject private var media = NowPlayingModel.shared
    @ObservedObject private var claude = ClaudeSessions.shared

    /// The colours each side of the closed island glows in.
    private var aura: (Color, Color, Double)? {
        switch kind {
        case .nowPlaying:
            if media.mode == .track, let d = media.duo { return (d.0, d.1, media.isPlaying ? 1 : 0.45) }
            return (media.accent, media.accent, media.isLive ? 0.7 : 0.35)
        case .claude:
            let waiting = claude.featured?.state == .waiting
            return (ClaudeSessions.tint, ClaudeSessions.tint, waiting ? 1 : 0.75)
        case .timer, .call, .meeting, .download, .custom: return (kind.tint, kind.tint, 0.7)
        case .flow: return (BrainStyle.tint, BrainStyle.tint, 0.5)
        case .shelf, .awake: return nil
        }
    }

    var body: some View {
        let wing = model.wing(for: kind)
        CompactLayout(notch: model.notch, wing: wing) {
            switch kind {
            case .nowPlaying: NowPlayingPresentation.Leading(ns: ns, notchHeight: model.notch.height)
            case .timer: TimerPresentation.Leading(ns: ns)
            case .meeting: MeetingPresentation.Leading()
            case .download: DownloadPresentation.Leading()
            case .shelf: ShelfPresentation.Leading()
            case .awake: AwakePresentation.Leading()
            case .flow: FlowPresentation.Leading()
            case .call: CallPresentation.Leading()
            case .custom: CustomPresentation.Leading()
            case .claude: ClaudePresentation.Leading()
            }
        } trailing: {
            HStack(spacing: 5) {
                switch kind {
                case .nowPlaying: NowPlayingPresentation.Trailing(ns: ns, notchHeight: model.notch.height)
                case .timer: TimerPresentation.Trailing(ns: ns)
                case .meeting: MeetingPresentation.Trailing()
                case .download: DownloadPresentation.Trailing()
                case .shelf: ShelfPresentation.Trailing()
                case .awake: AwakePresentation.Trailing()
                case .flow: FlowPresentation.Trailing()
                case .call: CallPresentation.Trailing()
                case .custom: CustomPresentation.Trailing()
                case .claude: ClaudePresentation.Trailing()
                }
            }
        }
        .background {
            if let a = aura { CompactAura(left: a.0, right: a.1, wing: wing, notch: model.notch, strength: a.2) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ActivitySummary.text(for: kind))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Shows details")
    }
}

struct ActivityMinimal: View {
    let kind: ActivityKind
    let diameter: CGFloat

    var body: some View {
        Group {
            switch kind {
            case .nowPlaying: NowPlayingPresentation.Minimal(diameter: diameter)
            case .timer: TimerPresentation.Minimal(diameter: diameter)
            case .meeting: MeetingPresentation.Minimal()
            case .download: DownloadPresentation.Minimal(diameter: diameter)
            case .shelf: ShelfPresentation.Minimal()
            case .awake: AwakePresentation.Minimal()
            case .flow: FlowPresentation.Leading()
            case .call: CallPresentation.Minimal(diameter: diameter)
            case .custom: CustomPresentation.Minimal(diameter: diameter)
            case .claude: ClaudePresentation.Minimal(diameter: diameter)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ActivitySummary.text(for: kind))
    }
}

struct ActivityExpanded: View {
    let kind: ActivityKind
    var model: IslandModel
    let ns: Namespace.ID

    var body: some View {
        switch kind {
        case .nowPlaying: NowPlayingPresentation.Expanded(model: model, ns: ns)
        case .timer: TimerPresentation.Expanded(model: model, ns: ns)
        case .meeting: MeetingPresentation.Expanded(model: model)
        case .download: DownloadPresentation.Expanded(model: model)
        case .shelf: ShelfPresentation.Expanded(model: model)
        case .awake: AwakePresentation.Expanded(model: model)
        case .flow: FlowPresentation.Expanded(model: model)
        case .call: CallPresentation.Expanded(model: model)
        case .custom: CustomPresentation.Expanded(model: model)
        case .claude: ClaudePresentation.Expanded(model: model)
        }
    }
}

/// Spoken summaries for VoiceOver.
@MainActor
enum ActivitySummary {
    static func text(for kind: ActivityKind) -> String {
        switch kind {
        case .nowPlaying:
            let m = NowPlayingModel.shared
            if m.mode == .app, let app = m.otherApp { return "\(app.name) is playing audio" }
            return m.artist.isEmpty ? "Now playing, \(m.title)" : "Now playing, \(m.title) by \(m.artist)"
        case .timer:
            let t = FocusTimer.shared
            return "\(t.label) timer, \(t.clock) remaining\(t.phase == .paused ? ", paused" : "")"
        case .meeting:
            guard let e = ActivityCenter.shared.meeting else { return "Meeting" }
            return "\(e.title), \(CalendarModel.relative(e))"
        case .download:
            let d = DownloadsWatcher.shared.active
            return "Downloading \(d?.name ?? "file")" + (d?.progress.map { ", \(Int($0 * 100)) percent" } ?? "")
        case .shelf:
            let n = ShelfModel.shared.items.count
            return "Shelf, \(n) item\(n == 1 ? "" : "s")"
        case .awake:
            return "Keeping Mac awake"
        case .flow:
            switch FlowInbox.shared.top?.body {
            case .question(let q): return "Flow is asking: \(q.text)"
            case .suggestion(let s): return "Flow suggests: \(s.title)"
            case nil: return "Flow"
            }
        case .call:
            let c = ActivityCenter.shared.call
            return "On a call\(c.map { " in \($0.app.name)" } ?? "")"
        case .claude:
            guard let s = ClaudeSessions.shared.featured else { return "Claude" }
            return s.state == .waiting ? "Claude needs your input in \(s.name)" : "Claude is working on \(s.name)"
        case .custom:
            let a = CustomActivity.shared.current
            return [a?.title, a?.detail].compactMap { $0 }.joined(separator: ", ")
        }
    }
}
