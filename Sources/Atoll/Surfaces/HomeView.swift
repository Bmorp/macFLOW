import SwiftUI

/// What the island opens to when nothing else needs you: your music and your apps, one click away,
/// with the date, weather and battery sitting beside the notch.
struct HomeView: View {
    var model: IslandModel
    @ObservedObject private var claude = ClaudeSessions.shared
    @ObservedObject private var now = NowModel.shared

    static let claudeStripHeight: CGFloat = 40
    @MainActor static var showsClaude: Bool { Prefs.shared.claude && !ClaudeSessions.shared.sessions.isEmpty }
    /// Now's card, when there's a moment: what matters right now is the first thing you see.
    @MainActor static var momentHeight: CGFloat { NowModel.shared.height }

    private var inset: CGFloat { IslandModel.expandedFlare + 18 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // With live activities, the tab switcher sits here instead (drawn by the island).
                if model.tabs.count > 1 { Color.clear.frame(width: 1) } else { HomeStatusLeading() }
                Spacer(minLength: model.notch.width + 24)
                HomeStatusTrailing(model: model)
            }
            .padding(.horizontal, inset)
            .frame(height: model.notch.height)

            if let moment = now.moment {
                NowSlot(moment: moment) { model.collapse() }
                    .padding(.horizontal, inset - 6)
                    .padding(.top, 2)
                    .padding(.bottom, FlowInboxCard.gap - 2)
                    .transition(.asymmetric(insertion: .identity, removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))))
            }

            HStack(spacing: 18) {
                HomeMedia(model: model)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(DS.Ink.hairline).frame(width: 1, height: 64)
                HomeApps(model: model)
            }
            .padding(.horizontal, inset)
            .padding(.top, 4)
            .padding(.bottom, Self.showsClaude ? 6 : 18)
            .frame(height: DS.Size.homeHeight - (Self.showsClaude ? 12 : 0))

            if Self.showsClaude {
                ClaudeStrip { model.collapse() }
                    .padding(.horizontal, inset)
                    .padding(.bottom, 14)
                    .frame(height: Self.claudeStripHeight + 12)
            }
        }
        .frame(width: model.expandedSize(.glance).width, alignment: .top)
        .overlay(alignment: .bottom) { SheetGrabber { model.open(.sheet) }.padding(.bottom, 4) }
        .background(alignment: .top) { ArtField(clearTop: model.notch.height / max(1, model.expandedSize(.glance).height), ambient: true) }
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
            GlyphButton(symbol: "slider.horizontal.3", label: "Sound & Display", size: 12, tint: DS.Palette.label, hit: 26) {
                model.select(.controls)
            }
            GlyphButton(symbol: "magnifyingglass", label: "Search", size: 12, tint: DS.Palette.label, hit: 26) {
                model.openSearch()
            }
        }
    }
}

// MARK: - Music

private struct HomeMedia: View {
    var model: IslandModel
    @Environment(\.islandShowing) private var showing
    @ObservedObject private var media = NowPlayingModel.shared

    var body: some View {
        if media.mode == .idle { idle } else { player }
    }

    private var playing: Bool { media.mode == .app || media.isPlaying }

    private var player: some View {
        HStack(spacing: 14) {
            Button { media.openCurrentApp() } label: {
                ImmersiveArtwork(size: 72)
                    .tilt(8, corner: 72 * 0.24, size: CGSize(width: 72, height: 72))
            }
            .buttonStyle(PressStyle(scale: 0.95))
            .help("Open \(media.source?.name ?? media.otherApp?.name ?? "Player")")
            .accessibilityLabel("Open player")

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: media.mode == .app ? (media.otherApp?.name ?? "Audio") : media.title,
                                font: DS.Kit.title, color: DS.Ink.primary)
                    Text(media.mode == .app ? "Playing audio" : (media.artist.isEmpty ? media.album : media.artist))
                        .font(DS.Kit.meta)
                        .foregroundStyle(DS.Ink.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 2)
                HStack(spacing: 0) {
                    Ghost(symbol: "backward.fill", label: "Previous", size: 13, hit: 30) { media.previous() }
                    Ghost(symbol: playing ? "pause.fill" : "play.fill", label: playing ? "Pause" : "Play", size: 19, weight: .bold, hit: 34) {
                        media.playPause()
                    }
                    Ghost(symbol: "forward.fill", label: "Next", size: 13, hit: 30) { media.next() }
                    Spacer(minLength: 8)
                    if media.mode == .track, media.duration > 0 {
                        TimelineView(PeriodicTimelineSchedule.seconds(showing)) { ctx in
                            ProgressLine(fraction: media.position(at: ctx.date) / media.duration, tint: .white) { f in
                                media.seek(to: f * media.duration)
                            }
                        }
                        .frame(maxWidth: 110)
                    } else {
                        Waveform(tint: DS.Ink.secondary, active: media.isLive, bars: 5, height: 14, barWidth: 2.5)
                    }
                }
                .padding(.leading, -8)
                .disabled(!media.canControl)
            }
            .frame(height: 72)
        }
    }

    /// Nothing playing: no placeholder art — just an invitation, and your players one click away.
    private var idle: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: "Nothing playing")
                Text("Pick up where you left off").font(DS.Kit.titleLarge).foregroundStyle(DS.Ink.primary).lineLimit(1)
            }
            HStack(spacing: 6) {
                ForEach(MediaSource.allCases.filter(\.isInstalled), id: \.self) { source in
                    SourceChip(source: source) { media.open(source) }
                }
            }
        }
    }
}

private struct SourceChip: View {
    let source: MediaSource
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = source.icon { IconImage(image: icon, size: 16) }
                Text(source.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Ink.primary)
            }
            .padding(.leading, 8)
            .padding(.trailing, 11)
            .frame(height: 28)
            .background(Capsule().fill(hover ? DS.Ink.wellHover : DS.Ink.well))
            .contentShape(Capsule())
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityLabel("Open \(source.name)")
    }
}

// MARK: - Apps

/// Your apps — the ones you open from Atoll first, then your favourites — one click to launch.
private struct HomeApps: View {
    var model: IslandModel
    @ObservedObject private var catalog = AppCatalog.shared

    private var apps: [AppEntry] {
        var list = catalog.recentEntries
        for p in catalog.pinnedEntries where !list.contains(p) { list.append(p) }
        return Array(list.prefix(8))
    }

    var body: some View {
        let items = apps
        Grid(horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow { ForEach(items.prefix(4)) { AppTile(entry: $0, model: model) } }
            GridRow { ForEach(Array(items.dropFirst(4).prefix(4))) { AppTile(entry: $0, model: model) } }
        }
        .frame(width: 4 * 38 + 3 * 12, alignment: .leading)
    }
}

private struct AppTile: View {
    let entry: AppEntry
    var model: IslandModel
    @State private var hover = false

    var body: some View {
        Button {
            Haptics.confirm()
            AppCatalog.shared.launch(entry)
            model.collapse()
        } label: {
            IconImage(image: AppCatalog.shared.icon(for: entry), size: 38)
                .scaleEffect(hover ? 1.16 : 1, anchor: .center)
                .shadow(color: .black.opacity(hover ? 0.4 : 0), radius: 4, y: 2)
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .onHover { h in withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) { hover = h } }
        .help(entry.name)
        .accessibilityLabel("Open \(entry.name)")
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
