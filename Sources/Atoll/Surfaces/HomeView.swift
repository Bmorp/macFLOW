import SwiftUI
import Combine

/// What the island opens to when nothing else needs you: what matters now, large, and what's next on your list, quiet
/// beside it; your apps along the foot, and your Claude sessions under them. The date, weather and battery sit beside
/// the notch.
///
///      date · weather          (notch)          battery · Flow · sound · search
///      ┌─ hero (Prism card) ──────────┐  TODAY                          3 open ›
///      │ FOCUSING                12 min│  ◯ Review Priya’s PR
///      │ Write the launch post         │  ◯ Inbox zero
///      │ [Done] ‖                      │  ◯ Reply to Sam
///      └───────────────────────────────┘
///      ▢ ▢ ▢ ▢ ▢ ▢ ▢ ▢                                  (a small player when music isn’t the hero)
struct HomeView: View {
    var model: IslandModel
    @ObservedObject private var claude = ClaudeSessions.shared
    @ObservedObject private var now = NowModel.shared
    @ObservedObject private var active = TaskStore.shared.active
    @ObservedObject private var calendar = CalendarModel.shared
    @ObservedObject private var media = NowPlayingModel.shared
    /// The focus timer's label while it runs or is paused. Held as state so its once-a-second ticks don't re-render Home.
    @State private var timerLabel: String? = FocusTimer.shared.isActive ? FocusTimer.shared.label : nil

    static let claudeStripHeight: CGFloat = 40
    /// The strip along the foot: the activity stack (running activities, finished work, Claude sessions).
    @MainActor static var showsStrip: Bool { !ActivityStack.isEmpty }
    @MainActor static var showsClaude: Bool { Prefs.shared.claude && !ClaudeSessions.shared.sessions.isEmpty }

    static let heroWidth: CGFloat = 322
    static let heroHeight: CGFloat = 116
    /// The row of apps, with its air.
    static let dockHeight: CGFloat = 66
    /// Everything between the status row and the Claude strip. The island sizes Home as `DS.Size.homeHeight` plus
    /// this much more: `momentHeight` is that difference, so the island's own arithmetic keeps working.
    static let bodyHeight: CGFloat = 4 + heroHeight + dockHeight
    @MainActor static var momentHeight: CGFloat { bodyHeight - DS.Size.homeHeight + (showsStrip ? 0 : footRoom) }
    /// Air under the carousel for the sheet's grabber when the Claude strip isn't there to hold it.
    static let footRoom: CGFloat = 10

    private var inset: CGFloat { IslandModel.expandedFlare + 18 }

    private var kind: HomeHeroKind {
        var flow: FlowInbox.Item?
        if case .flow(let item)? = now.moment { flow = item }
        return .resolve(flow: flow, activeTask: active.task?.id, timer: timerLabel, meetings: calendar.events, moment: now.moment, music: media.mode != .idle)
    }

    var body: some View {
        let kind = kind
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // With live activities, the tab switcher sits here instead (drawn by the island).
                if model.tabs.count > 1 { Color.clear.frame(width: 1) } else { HomeStatusLeading() }
                Spacer(minLength: model.notch.width + 24)
                HomeStatusTrailing(model: model)
            }
            .padding(.horizontal, inset)
            .frame(height: model.notch.height)

            HStack(alignment: .top, spacing: 20) {
                HomeHero(kind: kind, model: model)
                TodayStrip(model: model)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, inset)
            .padding(.top, 4)
            .frame(height: 4 + Self.heroHeight, alignment: .top)

            HomeDock(model: model, showsPlayer: kind != .music && media.mode != .idle)
                .padding(.horizontal, inset)
                .frame(height: Self.dockHeight - (Self.showsStrip ? 12 : 0))

            if !Self.showsStrip { Color.clear.frame(height: Self.footRoom) }
            if Self.showsStrip {
                ActivityStack(model: model) { model.collapse() }
                    .padding(.horizontal, inset)
                    .padding(.bottom, 14)
                    .frame(height: Self.claudeStripHeight + 12)
            }
        }
        .frame(width: model.expandedSize(.glance).width, alignment: .top)
        .overlay(alignment: .bottom) { SheetGrabber { if Prefs.shared.pullOpensWorkspace { model.openWorkspace() } else { model.open(.sheet) } }.padding(.bottom, 4) }
        .background(alignment: .top) { ArtField(clearTop: model.notch.height / max(1, model.expandedSize(.glance).height), strength: 0.42, ambient: true) }
        .onReceive(FocusTimer.shared.$phase.combineLatest(FocusTimer.shared.$label)) { phase, label in
            let next = phase == .idle ? nil : label
            if next != timerLabel { timerLabel = next }
        }
    }
}

// MARK: - Status beside the notch

private struct HomeStatusLeading: View {
    @ObservedObject private var weather = WeatherService.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            HStack(spacing: 10) {
                Text(ctx.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Ink.primary)
                if prefs.weatherEnabled, let w = weather.snapshot {
                    HStack(spacing: 4) {
                        Image(systemName: WeatherService.symbol(w.code, day: w.isDay))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 12))
                        Text("\(Int(w.temp.rounded()))°")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DS.Palette.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(Int(w.temp.rounded())) degrees, \(WeatherService.describe(w.code))")
                }
            }
            .lineLimit(1)
        }
    }
}

private struct HomeStatusTrailing: View {
    var model: IslandModel
    @ObservedObject private var battery = BatteryMonitor.shared

    var body: some View {
        HStack(spacing: 6) {
            if battery.hasBattery {
                HStack(spacing: 5) {
                    Text("\(battery.level)%")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(DS.Palette.secondary)
                        .fixedSize()
                    BatteryGlyph(level: battery.level, charging: battery.isCharging, width: 22)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Battery \(battery.level) percent\(battery.isCharging ? ", charging" : "")")
            }
            if Mind.shared.isAvailable {
                FlowButton { model.openBrain() }
            }
            GlyphButton(symbol: "square.grid.2x2", label: "Workspace", size: 12, tint: DS.Palette.label, hit: 26) {
                model.openWorkspace()
            }
            GlyphButton(symbol: "slider.horizontal.3", label: "Sound & Display", size: 12, tint: DS.Palette.label, hit: 26) {
                model.select(.controls)
            }
            GlyphButton(symbol: "magnifyingglass", label: "Search", size: 12, tint: DS.Palette.label, hit: 26) {
                model.openSearch()
            }
        }
    }
}

// MARK: - Dock

/// The foot of Home: your apps and Mac Flow's features on one carousel. When music plays but isn't the hero
/// (a task or a meeting is), a small player takes the right end.
private struct HomeDock: View {
    var model: IslandModel
    var showsPlayer: Bool

    var body: some View {
        HStack(spacing: 18) {
            HomeCarousel(model: model)
            if showsPlayer { MiniPlayer() }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The player when it isn't the hero: the cover, what's playing, and play/pause.
private struct MiniPlayer: View {
    @ObservedObject private var media = NowPlayingModel.shared

    var body: some View {
        let playing = media.mode == .app || media.isPlaying
        HStack(spacing: 9) {
            Button { media.openCurrentApp() } label: {
                LeadArtwork().frame(width: 32, height: 32)
                    .overlay(RoundedRectangle(cornerRadius: 32 * 0.23, style: .continuous).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
            }
            .buttonStyle(PressStyle(scale: 0.93))
            .accessibilityLabel("Open player")
            VStack(alignment: .leading, spacing: 1) {
                Text(media.mode == .app ? (media.otherApp?.name ?? "Audio") : media.title)
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Ink.primary).lineLimit(1)
                Text(media.mode == .app ? "Playing audio" : media.artist)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Ink.secondary).lineLimit(1)
            }
            .frame(width: 88, alignment: .leading)
            Ghost(symbol: playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play", size: 14, weight: .bold, hit: 30) { media.playPause() }
                .disabled(!media.canControl)
        }
    }
}

/// Opens Flow: the star from the Mac Flow mark, in a soft hover well.
private struct FlowButton: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            FlowGlyph(size: 12)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hover ? DS.Palette.fill : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help("Ask Flow")
        .accessibilityLabel("Ask Flow")
    }
}

/// The sheet's handle at the foot of Home: pull down with two fingers, or click it.
private struct SheetGrabber: View {
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(Color.white.opacity(hover ? 0.55 : 0.22))
                .frame(width: hover ? 44 : 34, height: 4)
                .frame(width: 80, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) { hover = h } }
        .help("Pull down for today")
        .accessibilityLabel("Open today’s sheet")
    }
}
