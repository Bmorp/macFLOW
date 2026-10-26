import SwiftUI
import SystemConfiguration
import AppKit
import UniformTypeIdentifiers

/// Picks the content view for a widget kind.
struct WidgetContent: View {
    let kind: WidgetKind

    var body: some View {
        switch kind {
        case .nowPlaying: NowPlayingWidget()
        case .upNext: UpNextWidget()
        case .weather: WeatherWidget()
        case .worldClock: WorldClockWidget()
        case .batteries: BatteriesWidget()
        case .timer: TimerWidget()
        case .reminders: RemindersWidget()
        case .system: SystemWidget()
        case .shortcuts: ShortcutsWidget()
        case .shelf: ShelfWidget()
        }
    }
}

/// The full-colour background for a kind. Only Now Playing and Weather carry colour of their own.
struct WidgetBackdrop: View {
    let kind: WidgetKind
    var body: some View {
        switch kind {
        case .nowPlaying: NowPlayingBackdrop()
        case .weather: WeatherBackdrop()
        default: StandardBackdrop()
        }
    }
}

private extension View {
    /// Colourful backgrounds always take light-on-dark content; elsewhere follow the system.
    func onColour(_ active: Bool, style: WidgetStyle, scheme: ColorScheme) -> some View {
        environment(\.colorScheme, active && style == .desktop ? .dark : scheme)
    }
}

// MARK: - Now Playing

private struct NowPlayingBackdrop: View {
    @ObservedObject private var np = NowPlayingModel.shared
    var body: some View {
        if np.mode == .track {
            let base = NSColor(np.accent).usingColorSpace(.sRGB) ?? .systemIndigo
            LinearGradient(colors: [Color(nsColor: base.blended(withFraction: 0.38, of: .black) ?? base),
                                    Color(nsColor: base.blended(withFraction: 0.66, of: .black) ?? base)],
                           startPoint: .top, endPoint: .bottom)
                .animation(.smooth(duration: 0.8), value: np.accent)
        } else {
            StandardBackdrop()
        }
    }
}

struct NowPlayingWidget: View {
    @ObservedObject private var np = NowPlayingModel.shared
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetStyle) private var style
    @Environment(\.colorScheme) private var scheme

    private var trackKey: String { np.mode == .app ? (np.otherApp?.id ?? "") : "\(np.title)|\(np.artist)" }
    private var title: String { np.mode == .app ? (np.otherApp?.name ?? "") : np.title }
    private var subtitle: String { np.mode == .app ? "Playing audio" : np.artist }

    var body: some View {
        Group {
            if np.mode == .idle {
                WidgetPrompt(symbol: "music.note", message: "Nothing is playing.", action: "Open Music", tint: DS.Palette.red) {
                    np.open(MediaSource.music.isInstalled ? .music : .spotify)
                }
            } else if family == .small {
                small
            } else {
                medium
            }
        }
        .onColour(np.mode == .track, style: style, scheme: scheme)
        .animation(Motion.duo, value: trackKey)
    }

    @ViewBuilder private var art: some View {
        if np.mode == .app, let icon = np.otherApp?.icon {
            IconImage(image: icon, size: family == .small ? 56 : 120)
        } else {
            Artwork(image: np.artwork, size: family == .small ? 60 : 142, radius: family == .small ? 10 : WidgetMetrics.innerRadius, accent: np.accent)
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                art.id(trackKey).transition(.duo)
                Spacer(minLength: 0)
                PlayPauseDisc(playing: np.isPlaying || np.mode == .app, diameter: 34, enabled: np.canControl) { np.playPause() }
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(WidgetType.headline).lineLimit(1)
                Text(subtitle).font(WidgetType.captionNumeric).foregroundStyle(.secondary).lineLimit(1)
            }
            .id(trackKey).transition(.duo(anchor: .bottomLeading))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { np.openCurrentApp() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(subtitle)")
    }

    private var medium: some View {
        HStack(spacing: 14) {
            art
                .frame(width: 142, height: 142)
                .id(trackKey).transition(.duo)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Waveform(tint: .primary, active: np.isPlaying || np.mode == .app, bars: 4, height: 10, barWidth: 2)
                    Text((np.mode == .app ? np.otherApp?.name : np.source?.name) ?? "")
                        .font(WidgetType.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(WidgetType.title).lineLimit(2)
                    Text(subtitle).font(WidgetType.body).foregroundStyle(.secondary).lineLimit(1)
                }
                .id(trackKey).transition(.duo(anchor: .leading))
                Spacer(minLength: 6)
                if np.mode == .track, np.duration > 0 {
                    TrackProgress(np: np)
                        .padding(.bottom, 8)
                }
                HStack(spacing: 4) {
                    GlyphButton(symbol: "backward.fill", label: "Previous", size: 14, tint: .primary, hit: 30) { np.previous() }
                    PlayPauseDisc(playing: np.isPlaying || np.mode == .app, diameter: 32, enabled: np.canControl) { np.playPause() }
                    GlyphButton(symbol: "forward.fill", label: "Next", size: 14, tint: .primary, hit: 30) { np.next() }
                }
                .disabled(!np.canControl)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: .infinity)
    }
}

/// Play / pause in a soft disc — the one control a glance needs.
private struct PlayPauseDisc: View {
    let playing: Bool
    var diameter: CGFloat
    var enabled = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: playing ? "pause.fill" : "play.fill")
                .font(.system(size: diameter * 0.4, weight: .bold))
                .foregroundStyle(.primary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: diameter, height: diameter)
                .background(Circle().fill(Color.primary.opacity(hover ? 0.22 : 0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .disabled(!enabled)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityLabel(playing ? "Pause" : "Play")
        .help(playing ? "Pause" : "Play")
    }
}

private struct TrackProgress: View {
    @ObservedObject var np: NowPlayingModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let pos = min(np.position(at: ctx.date), np.duration)
            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.2))
                        Capsule().fill(Color.primary).frame(width: max(4, geo.size.width * pos / max(np.duration, 1)))
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(pos.clock)
                    Spacer()
                    Text("−" + max(0, np.duration - pos).clock)
                }
                .font(WidgetType.captionNumeric)
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Elapsed \(Int(np.position())) of \(Int(np.duration)) seconds")
    }
}

// MARK: - Up Next

struct UpNextWidget: View {
    @ObservedObject private var cal = CalendarModel.shared
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if cal.access != .granted {
            WidgetPrompt(symbol: "calendar", message: family == .small ? "See your next event." : "See your next meeting and join it in one click.",
                         action: "Allow Access", tint: DS.Palette.red) { cal.requestAccess() }
        } else {
            TimelineView(.everyMinute) { ctx in
                content(now: ctx.date)
            }
        }
    }

    private func upcoming(_ now: Date) -> [CalendarModel.Event] { cal.events.filter { $0.end > now } }

    @ViewBuilder private func content(now: Date) -> some View {
        let events = upcoming(now)
        let today = events.filter { Calendar.current.isDate($0.start, inSameDayAs: now) || $0.start < now }
        switch family {
        case .small:
            VStack(alignment: .leading, spacing: 0) {
                DateBadge(date: now, size: 30)
                Spacer(minLength: 6)
                if let e = today.first {
                    EventRow(event: e, now: now, dense: true)
                    if today.count > 1 {
                        Text("\(today.count - 1) more today").font(WidgetType.captionNumeric).foregroundStyle(.secondary).padding(.top, 4)
                    }
                } else {
                    NoEvents(next: events.first)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .medium:
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 0) {
                    DateBadge(date: now, size: 40)
                    Spacer(minLength: 0)
                    if today.count > 3 {
                        Text("\(today.count - 3) more").font(WidgetType.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 84, alignment: .leading)
                .frame(maxHeight: .infinity)
                VStack(spacing: 6) {
                    if today.isEmpty {
                        NoEvents(next: events.first).frame(maxHeight: .infinity, alignment: .bottomLeading)
                    } else {
                        ForEach(today.prefix(3)) { e in EventRow(event: e, now: now, dense: false) }
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        case .large:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    DateBadge(date: now, size: 32)
                    Spacer()
                    Text(now.formatted(.dateTime.month(.wide).year()))
                        .font(WidgetType.caption).foregroundStyle(.secondary)
                }
                if events.isEmpty {
                    NoEvents(next: nil).frame(maxHeight: .infinity, alignment: .center)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(events.prefix(6).enumerated()), id: \.element.id) { i, e in
                            if !Calendar.current.isDate(e.start, inSameDayAs: now), e.start > now,
                               i == 0 || Calendar.current.isDate(events[i - 1].start, inSameDayAs: now) || events[i - 1].start < now {
                                Text("Tomorrow".uppercased()).font(WidgetType.caption).foregroundStyle(.secondary).padding(.top, 4)
                            }
                            EventRow(event: e, now: now, dense: false)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

private struct DateBadge: View {
    let date: Date
    var size: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: -2) {
            Text(date.formatted(.dateTime.weekday(.wide)).uppercased())
                .font(WidgetType.caption)
                .foregroundStyle(DS.Palette.red)
            Text(date.formatted(.dateTime.day()))
                .font(WidgetType.display(size, weight: .regular))
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct NoEvents: View {
    let next: CalendarModel.Event?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("No more events today").font(WidgetType.headline).foregroundStyle(.secondary)
            if let next {
                Text("Tomorrow: \(next.title)").font(WidgetType.captionNumeric).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

private struct EventRow: View {
    let event: CalendarModel.Event
    let now: Date
    var dense: Bool
    @State private var hover = false

    private var joinable: Bool {
        guard event.meetingURL != nil else { return false }
        return event.isNow || event.start.timeIntervalSince(now) < 15 * 60
    }

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(event.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(WidgetType.headline).foregroundStyle(.primary).lineLimit(dense ? 2 : 1)
                Text(event.isNow || event.start.timeIntervalSince(now) < 3600 ? CalendarModel.relative(event) : CalendarModel.timeRange(event))
                    .font(WidgetType.captionNumeric).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if joinable, !dense {
                Button { CalendarModel.shared.open(event) } label: {
                    Text("Join")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .frame(height: 24)
                        .background(Capsule().fill(DS.Palette.green))
                }
                .buttonStyle(PressStyle(scale: 0.94))
                .accessibilityLabel("Join \(event.title)")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .fixedSize(horizontal: false, vertical: true)
        .background(ContainerRelativeShape().fill(event.color.opacity(hover ? 0.2 : 0.13)))
        .contentShape(ContainerRelativeShape())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .onTapGesture { CalendarModel.shared.open(event) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Weather

private enum WeatherLook {
    static func colors(code: Int, day: Bool) -> [Color] {
        if !day { return [Color(red: 0.06, green: 0.1, blue: 0.22), Color(red: 0.18, green: 0.23, blue: 0.38)] }
        switch code {
        case 0, 1: return [Color(red: 0.2, green: 0.48, blue: 0.86), Color(red: 0.42, green: 0.66, blue: 0.94)]
        case 2, 3, 45, 48: return [Color(red: 0.36, green: 0.46, blue: 0.58), Color(red: 0.55, green: 0.63, blue: 0.72)]
        default: return [Color(red: 0.26, green: 0.33, blue: 0.43), Color(red: 0.41, green: 0.48, blue: 0.57)]
        }
    }
}

private struct WeatherBackdrop: View {
    @ObservedObject private var weather = WeatherService.shared
    @ObservedObject private var prefs = Prefs.shared
    var body: some View {
        if prefs.weatherEnabled, let s = weather.snapshot {
            LinearGradient(colors: WeatherLook.colors(code: s.code, day: s.isDay), startPoint: .top, endPoint: .bottom)
        } else {
            StandardBackdrop()
        }
    }
}

struct WeatherWidget: View {
    @ObservedObject private var weather = WeatherService.shared
    @ObservedObject private var prefs = Prefs.shared
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetStyle) private var style
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            if !prefs.weatherEnabled {
                WidgetPrompt(symbol: "cloud.sun.fill", message: "See the weather where you are.", action: "Turn On", tint: DS.Palette.blue) {
                    prefs.weatherEnabled = true
                }
            } else if let s = weather.snapshot {
                if family == .small { now(s) } else {
                    HStack(alignment: .top, spacing: 12) {
                        now(s).frame(width: 128)
                        hours(s)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(weather.status == .locating ? "Finding your location…" : "Getting the weather…")
                        .font(WidgetType.headline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .onColour(prefs.weatherEnabled && weather.snapshot != nil, style: style, scheme: scheme)
    }

    private func t(_ v: Double) -> String { "\(Int(v.rounded()))°" }

    private func now(_ s: WeatherService.Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Text(s.place).font(WidgetType.headline).lineLimit(1)
                Image(systemName: "location.fill").font(.system(size: 9, weight: .bold))
            }
            Text(t(s.temp))
                .font(WidgetType.display(40, weight: .regular))
                .contentTransition(.numericText(value: s.temp))
            Spacer(minLength: 0)
            Image(systemName: WeatherService.symbol(s.code, day: s.isDay))
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 15))
                .padding(.bottom, 2)
            Text(WeatherService.describe(s.code)).font(WidgetType.headline).lineLimit(1)
            Text("H:\(t(s.high)) L:\(t(s.low))").font(WidgetType.captionNumeric).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private func hours(_ s: WeatherService.Snapshot) -> some View {
        HStack(spacing: 0) {
            ForEach(s.hours.prefix(5)) { h in
                VStack(spacing: 8) {
                    Text(h.time.formatted(.dateTime.hour(.defaultDigits(amPM: .abbreviated))))
                        .font(WidgetType.captionNumeric).foregroundStyle(.secondary)
                    Image(systemName: WeatherService.symbol(h.code, day: h.isDay))
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 16))
                        .frame(height: 22)
                    Text(t(h.temp)).font(WidgetType.headline).monospacedDigit()
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }
}

// MARK: - World Clock

struct WorldClockWidget: View {
    @ObservedObject private var prefs = Prefs.shared
    @Environment(\.widgetFamily) private var family

    var body: some View {
        TimelineView(.everyMinute) { ctx in
            let zones = prefs.worldClocks.prefix(4).compactMap(TimeZone.init(identifier:))
            if family == .small {
                Grid(horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach(0..<2, id: \.self) { row in
                        GridRow {
                            ForEach(0..<2, id: \.self) { col in
                                let i = row * 2 + col
                                if i < zones.count { cell(zones[i], date: ctx.date, face: 46, detail: false) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ForEach(Array(zones.enumerated()), id: \.offset) { _, z in
                        cell(z, date: ctx.date, face: 62, detail: true).frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func cell(_ zone: TimeZone, date: Date, face: CGFloat, detail: Bool) -> some View {
        VStack(spacing: 5) {
            AnalogClock(date: date, zone: zone, seconds: false)
                .frame(width: face, height: face)
            VStack(spacing: 0) {
                Text(Self.city(zone)).font(WidgetType.caption).foregroundStyle(.primary).lineLimit(1)
                if detail {
                    let parts = Self.offsetParts(zone, date: date)
                    Text(parts.day).font(WidgetType.captionNumeric).foregroundStyle(.secondary).lineLimit(1)
                    if let hours = parts.hours {
                        Text(hours).font(WidgetType.captionNumeric).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Self.city(zone)), \(date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)))")
    }

    static func city(_ zone: TimeZone) -> String {
        (zone.identifier.split(separator: "/").last.map(String.init) ?? zone.identifier).replacingOccurrences(of: "_", with: " ")
    }

    /// "Yesterday" / "−5:30 h" — the day there, and how far ahead or behind it is.
    static func offsetParts(_ zone: TimeZone, date: Date) -> (day: String, hours: String?) {
        let diff = zone.secondsFromGMT(for: date) - TimeZone.current.secondsFromGMT(for: date)
        var cal = Calendar.current
        let here = cal.component(.day, from: date)
        cal.timeZone = zone
        let there = cal.component(.day, from: date)
        let day = there == here ? "Today" : (diff > 0 ? "Tomorrow" : "Yesterday")
        guard diff != 0 else { return (day, nil) }
        let h = abs(diff) / 3600, m = (abs(diff) % 3600) / 60
        return (day, "\(diff > 0 ? "+" : "−")\(h)\(m > 0 ? ":\(String(format: "%02d", m))" : "") h")
    }

    static func offset(_ zone: TimeZone, date: Date) -> String {
        let parts = offsetParts(zone, date: date)
        return parts.hours.map { "\(parts.day), \($0)" } ?? parts.day
    }
}

/// A clock face: light by day, dark by night in its own time zone — as in Clock.
struct AnalogClock: View {
    let date: Date
    var zone: TimeZone = .current
    var seconds: Bool
    var accent: Color = DS.Palette.orange
    /// StandBy: a dark face whatever the hour, with numerals.
    var ambient = false
    /// Off when something else (StandBy's glass dial) is the face.
    var drawsFace = true

    var body: some View {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        let c = cal.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        let hour = Double(c.hour ?? 0), minute = Double(c.minute ?? 0)
        let second = Double(c.second ?? 0) + Double(c.nanosecond ?? 0) / 1e9
        let night = ambient || hour < 6 || hour >= 18
        let ink: Color = night ? .white : .black
        return Canvas { ctx, size in
            let r = min(size.width, size.height) / 2
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let faceRect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
            if drawsFace {
                ctx.fill(Path(ellipseIn: faceRect), with: .color(ambient ? Color(white: 0.07) : night ? Color(white: 0.12) : Color(white: 0.97)))
                ctx.stroke(Path(ellipseIn: faceRect.insetBy(dx: 0.25, dy: 0.25)), with: .color(night ? .white.opacity(0.14) : .black.opacity(0.1)), lineWidth: 0.5)
            }
            // Hour ticks.
            for i in 0..<12 {
                let a = Double(i) / 12 * 2 * .pi
                let outer = r * 0.9, inner = r * (i % 3 == 0 ? 0.76 : 0.8)
                var p = Path()
                p.move(to: CGPoint(x: center.x + sin(a) * inner, y: center.y - cos(a) * inner))
                p.addLine(to: CGPoint(x: center.x + sin(a) * outer, y: center.y - cos(a) * outer))
                ctx.stroke(p, with: .color(ink.opacity(i % 3 == 0 ? 0.7 : 0.35)), style: StrokeStyle(lineWidth: max(1, r * 0.035), lineCap: .round))
                if ambient, i % 3 == 0 {
                    let label = ctx.resolve(Text("\(i == 0 ? 12 : i)").font(.system(size: r * 0.16, weight: .semibold, design: .rounded)).foregroundColor(ink))
                    ctx.draw(label, at: CGPoint(x: center.x + sin(a) * r * 0.6, y: center.y - cos(a) * r * 0.6))
                }
            }
            func hand(_ fraction: Double, length: CGFloat, width: CGFloat, color: Color, tail: CGFloat = 0) {
                let a = fraction * 2 * .pi
                var p = Path()
                p.move(to: CGPoint(x: center.x - sin(a) * tail, y: center.y + cos(a) * tail))
                p.addLine(to: CGPoint(x: center.x + sin(a) * length, y: center.y - cos(a) * length))
                ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
            }
            hand((hour.truncatingRemainder(dividingBy: 12) + minute / 60) / 12, length: r * 0.5, width: max(2, r * 0.085), color: ink)
            hand((minute + (seconds ? second / 60 : 0)) / 60, length: r * 0.76, width: max(1.6, r * 0.06), color: ink)
            if seconds {
                hand(second / 60, length: r * 0.82, width: max(1, r * 0.025), color: accent, tail: r * 0.16)
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - r * 0.05, y: center.y - r * 0.05, width: r * 0.1, height: r * 0.1)), with: .color(accent))
            } else {
                ctx.fill(Path(ellipseIn: CGRect(x: center.x - r * 0.055, y: center.y - r * 0.055, width: r * 0.11, height: r * 0.11)), with: .color(ink))
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Batteries

private struct BatteryItem: Identifiable {
    let id: String
    let name: String
    let symbol: String
    let level: Int
    let charging: Bool
}

struct BatteriesWidget: View {
    @ObservedObject private var battery = BatteryMonitor.shared
    @ObservedObject private var prefs = Prefs.shared
    @Environment(\.widgetFamily) private var family

    /// The Mac's name from the local configuration store — `Host.current()` can block on name resolution.
    private static let computerName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"

    private func items() -> [BatteryItem] {
        var list: [BatteryItem] = []
        if battery.hasBattery {
            list.append(BatteryItem(id: "mac", name: Self.computerName, symbol: "laptopcomputer", level: battery.level, charging: battery.isCharging))
        }
        for d in BluetoothMonitor.connectedDevices() {
            let level = d.single ?? [d.left, d.right].compactMap { $0 }.min() ?? 0
            list.append(BatteryItem(id: d.name, name: d.name, symbol: d.symbol, level: level, charging: false))
        }
        return Array(list.prefix(4))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            let list = items()
            if list.isEmpty {
                WidgetPrompt(symbol: "airpods", message: "See the battery of your AirPods and other devices.", action: prefs.devices ? nil : "Turn On", tint: DS.Palette.green) {
                    prefs.devices = true
                }
            } else if family == .small, list.count == 1, let only = list.first {
                VStack(alignment: .leading, spacing: 0) {
                    BatteryDial(item: only, size: 76, line: 7)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        Text("\(only.level)%").font(WidgetType.display(24, weight: .semibold)).contentTransition(.numericText(value: Double(only.level)))
                        if only.charging { Image(systemName: "bolt.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(DS.Palette.green) }
                    }
                    Text(caption(for: only)).font(WidgetType.captionNumeric).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if family == .medium, list.count == 1, let only = list.first {
                HStack(spacing: 22) {
                    BatteryDial(item: only, size: 104, line: 9)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(only.name).font(WidgetType.headline).foregroundStyle(.secondary).lineLimit(1)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text("\(only.level)%").font(WidgetType.display(40, weight: .semibold)).contentTransition(.numericText(value: Double(only.level)))
                            if only.charging { Image(systemName: "bolt.fill").font(.system(size: 18, weight: .bold)).foregroundStyle(DS.Palette.green) }
                        }
                        Text(caption(for: only, detailOnly: true)).font(WidgetType.captionNumeric).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            } else if family == .small {
                Grid(horizontalSpacing: 14, verticalSpacing: 10) {
                    ForEach(0..<2, id: \.self) { row in
                        GridRow {
                            ForEach(0..<2, id: \.self) { col in
                                let i = row * 2 + col
                                if i < list.count {
                                    VStack(spacing: 4) {
                                        BatteryDial(item: list[i], size: 46, line: 5)
                                        Text("\(list[i].level)%").font(WidgetType.captionNumeric)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    ForEach(list) { item in
                        VStack(spacing: 8) {
                            BatteryDial(item: item, size: 62, line: 6)
                            Text("\(item.level)%").font(WidgetType.headline).monospacedDigit()
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private func caption(for item: BatteryItem, detailOnly: Bool = false) -> String {
        if item.charging { return battery.isCharging && item.id == "mac" && battery.level >= 100 ? "Charged" : "Charging" }
        if item.id == "mac", let m = battery.minutesRemaining, m > 0 { return "\(m / 60):\(String(format: "%02d", m % 60)) remaining" }
        if item.id == "mac", battery.onAC { return "On power adapter" }
        return detailOnly ? "Connected" : item.name
    }
}

private struct BatteryDial: View {
    let item: BatteryItem
    var size: CGFloat
    var line: CGFloat

    private var tint: Color { item.level <= 20 && !item.charging ? DS.Palette.red : DS.Palette.green }

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.22), lineWidth: line)
            Circle()
                .trim(from: 0, to: max(0.01, Double(item.level) / 100))
                .stroke(tint, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.8), value: item.level)
            Image(systemName: item.charging ? "bolt.fill" : item.symbol)
                .font(.system(size: size * 0.32, weight: .semibold))
                .foregroundStyle(item.charging ? DS.Palette.green : .primary)
        }
        .frame(width: size, height: size)
        .padding(line / 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.name), \(item.level) percent\(item.charging ? ", charging" : "")")
    }
}

// MARK: - Focus Timer

struct TimerWidget: View {
    @ObservedObject private var timer = FocusTimer.shared

    var body: some View {
        Group {
            if timer.isActive { running } else { idle }
        }
        .animation(Motion.duo, value: timer.isActive)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetLabel(title: "Focus", symbol: "timer", tint: DS.Palette.orange)
            Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                GridRow { preset(0); preset(1) }
                GridRow { preset(2); preset(3) }
            }
        }
        .transition(.duo)
    }

    private func preset(_ i: Int) -> some View {
        let p = FocusTimer.presets[i]
        return PresetTile(minutes: p.minutes, label: p.label) {
            Haptics.confirm()
            timer.start(minutes: p.minutes, label: p.label)
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 0) {
            WidgetLabel(title: timer.label, symbol: "timer", tint: DS.Palette.orange)
            Spacer(minLength: 0)
            HStack(alignment: .center) {
                ZStack {
                    ProgressRing(progress: 1 - timer.progress, tint: DS.Palette.orange, lineWidth: 6)
                    Text(timer.clock)
                        .font(WidgetType.display(timer.remaining >= 3600 ? 14 : 18, weight: .semibold))
                        .contentTransition(.numericText(countsDown: true))
                        .foregroundStyle(timer.phase == .paused ? .secondary : .primary)
                }
                .frame(width: 80, height: 80)
                Spacer(minLength: 0)
                VStack(spacing: 8) {
                    CircleButton(symbol: timer.phase == .paused ? "play.fill" : "pause.fill", label: timer.phase == .paused ? "Resume" : "Pause",
                                 tint: DS.Palette.orange, diameter: 34) { timer.togglePause() }
                    CircleButton(symbol: "xmark", label: "Stop", tint: .secondary, diameter: 34) { timer.stop() }
                }
            }
            Spacer(minLength: 0)
            Text(timer.phase == .paused ? "Paused" : "Ends at \(Date().addingTimeInterval(timer.remaining).formatted(date: .omitted, time: .shortened))")
                .font(WidgetType.captionNumeric).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .transition(.duo)
    }
}

private struct PresetTile: View {
    let minutes: Int
    let label: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: -1) {
                Text("\(minutes)").font(WidgetType.display(20, weight: .semibold)).foregroundStyle(DS.Palette.orange)
                Text("min").font(WidgetType.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(ContainerRelativeShape().fill(DS.Palette.orange.opacity(hover ? 0.2 : 0.12)))
            .contentShape(ContainerRelativeShape())
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityLabel("Start \(minutes) minute \(label)")
        .help("\(label) · \(minutes) min")
    }
}

// MARK: - Reminders

struct RemindersWidget: View {
    @ObservedObject private var reminders = RemindersService.shared
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if reminders.access != .granted {
                WidgetPrompt(symbol: "checklist", message: "Check off reminders right from your desktop.", action: "Allow Access", tint: DS.Palette.blue) {
                    reminders.requestAccess()
                }
            } else if family == .large {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        ListGlyph()
                        Text("Reminders").font(WidgetType.title)
                        Spacer()
                        Text("\(reminders.items.filter { !$0.done }.count)")
                            .font(WidgetType.display(22, weight: .semibold)).foregroundStyle(DS.Palette.blue)
                            .contentTransition(.numericText())
                    }
                    list(limit: 9)
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 0) {
                        ListGlyph()
                        Spacer(minLength: 0)
                        Text("\(reminders.items.filter { !$0.done }.count)")
                            .font(WidgetType.display(30, weight: .semibold))
                            .contentTransition(.numericText())
                        Text("Reminders").font(WidgetType.headline).foregroundStyle(.secondary)
                    }
                    .frame(width: 84, alignment: .leading)
                    .frame(maxHeight: .infinity)
                    list(limit: 4)
                }
            }
        }
        .onAppear { reminders.watch() }
    }

    @ViewBuilder private func list(limit: Int) -> some View {
        if reminders.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 26)).foregroundStyle(DS.Palette.blue)
                Text("All done").font(WidgetType.headline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(reminders.items.prefix(limit).enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Divider().padding(.leading, 28) }
                    ReminderRow(item: item)
                        .transition(.duo(anchor: .leading))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .animation(Motion.duo, value: reminders.items.map(\.id))
        }
    }
}

private struct ListGlyph: View {
    var body: some View {
        Image(systemName: "list.bullet")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(Circle().fill(DS.Palette.blue))
            .accessibilityHidden(true)
    }
}

private struct ReminderRow: View {
    let item: RemindersService.Item

    /// "Today, 5:00 PM", "Tomorrow", "Sun, 10:00 AM", "20 Oct".
    static func short(_ due: Date) -> String {
        let cal = Calendar.current
        let time = due.formatted(date: .omitted, time: .shortened)
        let hasTime = cal.component(.hour, from: due) != 0 || cal.component(.minute, from: due) != 0
        if cal.isDateInToday(due) { return hasTime ? "Today, \(time)" : "Today" }
        if cal.isDateInTomorrow(due) { return hasTime ? "Tomorrow, \(time)" : "Tomorrow" }
        if cal.isDateInYesterday(due) { return "Yesterday" }
        if due > Date(), let week = cal.date(byAdding: .day, value: 6, to: Date()), due < week {
            return hasTime ? "\(due.formatted(.dateTime.weekday(.abbreviated))), \(time)" : due.formatted(.dateTime.weekday(.wide))
        }
        return due.formatted(.dateTime.day().month(.abbreviated))
    }

    var body: some View {
        HStack(spacing: 8) {
            Button {
                Haptics.confirm()
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { RemindersService.shared.complete(item) }
            } label: {
                ZStack {
                    Circle().strokeBorder(item.done ? item.color : Color.secondary.opacity(0.6), lineWidth: 1.5)
                    if item.done {
                        Circle().fill(item.color).padding(3)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: 20, height: 20)
                .frame(width: 24, height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel(item.done ? "Completed" : "Complete \(item.title)")
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                    .font(WidgetType.body)
                    .foregroundStyle(item.done ? .secondary : .primary)
                    .strikethrough(item.done, color: .secondary)
                    .lineLimit(1)
                if let due = item.due {
                    Text(Self.short(due))
                        .font(WidgetType.captionNumeric)
                        .foregroundStyle(item.isOverdue ? DS.Palette.red : .secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - System

struct SystemWidget: View {
    @ObservedObject private var stats = SystemStats.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                ring(stats.cpu, DS.Palette.blue, diameter: 78)
                ring(stats.memory, DS.Palette.green, diameter: 56)
                ring(stats.disk, DS.Palette.orange, diameter: 34)
            }
            .frame(width: 84, height: 84)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 1) {
                legend("CPU", stats.cpu, DS.Palette.blue)
                legend("Memory", stats.memory, DS.Palette.green)
                legend("Disk", stats.disk, DS.Palette.orange)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { stats.start() }
        .onDisappear { stats.stop() }
    }

    private func ring(_ value: Double, _ tint: Color, diameter: CGFloat) -> some View {
        ZStack {
            Circle().stroke(tint.opacity(0.2), lineWidth: 8)
            Circle()
                .trim(from: 0, to: max(0.01, value))
                .stroke(tint, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth(duration: 0.5), value: value)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }

    private func legend(_ name: String, _ value: Double, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(name).font(WidgetType.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text("\(Int((value * 100).rounded()))%")
                .font(WidgetType.captionNumeric)
                .contentTransition(.numericText(value: value))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(Int((value * 100).rounded())) percent")
    }
}

// MARK: - Shortcuts

struct ShortcutsWidget: View {
    @ObservedObject private var shortcuts = ShortcutsService.shared
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if shortcuts.names.isEmpty {
                WidgetPrompt(symbol: "square.stack.3d.up.fill", message: "Your shortcuts appear here.", action: "Open Shortcuts", tint: DS.Palette.indigo) {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    }
                }
            } else {
                let columns = family == .small ? 2 : 4
                let names = Array(shortcuts.names.prefix(columns * 2))
                Grid(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(0..<2, id: \.self) { row in
                        GridRow {
                            ForEach(0..<columns, id: \.self) { col in
                                let i = row * columns + col
                                if i < names.count { ShortcutTile(name: names[i]) } else { Color.clear }
                            }
                        }
                    }
                }
            }
        }
        .onAppear { shortcuts.refreshIfStale() }
    }
}

private struct ShortcutTile: View {
    let name: String
    @State private var hover = false
    @State private var ran = false

    private static let colors: [Color] = [
        Color(red: 0.0, green: 0.44, blue: 0.9), Color(red: 0.36, green: 0.3, blue: 0.86), Color(red: 0.93, green: 0.42, blue: 0.0),
        Color(red: 0.13, green: 0.6, blue: 0.3), Color(red: 0.86, green: 0.2, blue: 0.27), Color(red: 0.0, green: 0.55, blue: 0.65),
        Color(red: 0.8, green: 0.2, blue: 0.55), Color(red: 0.45, green: 0.45, blue: 0.5),
    ]

    private var color: Color { Self.colors[name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) } % Self.colors.count] }

    private var symbol: String {
        let n = name.lowercased()
        let table: [(String, String)] = [("timer", "timer"), ("music", "music.note"), ("play", "play.fill"), ("home", "house.fill"),
                                         ("light", "lightbulb.fill"), ("mail", "envelope.fill"), ("message", "message.fill"),
                                         ("photo", "photo.fill"), ("screenshot", "camera.viewfinder"), ("note", "note.text"),
                                         ("focus", "moon.fill"), ("weather", "cloud.sun.fill"), ("text", "textformat"),
                                         ("file", "doc.fill"), ("clip", "doc.on.clipboard.fill"), ("web", "safari.fill"), ("search", "magnifyingglass")]
        return table.first { n.contains($0.0) }?.1 ?? "square.stack.3d.up.fill"
    }

    var body: some View {
        Button {
            Haptics.confirm()
            ShortcutsService.shared.run(name)
            withAnimation(Motion.duo) { ran = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { withAnimation(Motion.duo) { ran = false } }
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    if ran {
                        Image(systemName: "checkmark").transition(.duo)
                    } else {
                        Image(systemName: symbol).transition(.duo)
                    }
                }
                .font(.system(size: 14, weight: .bold))
                Spacer(minLength: 0)
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(.white)
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(ContainerRelativeShape().fill(color.gradient))
            .overlay(ContainerRelativeShape().fill(Color.white.opacity(hover ? 0.1 : 0)))
            .contentShape(ContainerRelativeShape())
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityLabel("Run \(name)")
        .help("Run “\(name)”")
    }
}

// MARK: - Shelf

struct ShelfWidget: View {
    @ObservedObject private var shelf = ShelfModel.shared
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                WidgetLabel(title: "Shelf", symbol: "tray.full.fill", tint: DS.Palette.indigo)
                Spacer()
                if !shelf.items.isEmpty {
                    Text(shelf.items.count == 1 ? "1 item" : "\(shelf.items.count) items").font(WidgetType.captionNumeric).foregroundStyle(.secondary)
                }
            }
            if shelf.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 22, weight: .medium)).foregroundStyle(DS.Palette.indigo)
                    Text("Drop files here to keep them handy.").font(WidgetType.headline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ContainerRelativeShape().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])).foregroundStyle(targeted ? DS.Palette.indigo : Color.secondary.opacity(0.4)))
            } else {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(shelf.items.suffix(5).reversed()) { item in
                        ShelfTile(item: item, thumbnail: shelf.thumbnails[item.path])
                            .transition(.duo)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .animation(Motion.duo, value: shelf.items.map(\.id))
            }
        }
        .background(ContainerRelativeShape().fill(DS.Palette.indigo.opacity(targeted ? 0.1 : 0)).padding(-6))
        .fileDropTarget(isTargeted: $targeted) { providers in
            shelf.add(providers: providers)
        }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }
}

private struct ShelfTile: View {
    let item: ShelfItem
    let thumbnail: NSImage?
    @State private var hover = false

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit)
                } else {
                    IconImage(image: IconCache.file(item.path), size: 52)
                }
            }
            .frame(width: 52, height: 52)
            .scaleEffect(hover ? 1.06 : 1)
            Text(item.path.hasSuffix(".app") ? (item.name as NSString).deletingPathExtension : item.name)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 58)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hover = h } }
        .onTapGesture(count: 2) { ShelfModel.shared.open(item) }
        .onDrag { NSItemProvider(object: item.url as NSURL) }
        .contextMenu {
            Button("Open") { ShelfModel.shared.open(item) }
            Button("Show in Finder") { ShelfModel.shared.reveal([item]) }
            Divider()
            Button("Remove from Shelf") { ShelfModel.shared.remove(item) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .help(item.name)
    }
}

extension View {
    /// Accepts dropped files — skipped in offscreen snapshots, which can't host drop targets.
    @ViewBuilder func fileDropTarget(isTargeted: Binding<Bool>, perform: @escaping ([NSItemProvider]) -> Bool) -> some View {
        if RenderMode.snapshot {
            self
        } else {
            onDrop(of: [.fileURL], isTargeted: isTargeted, perform: perform)
        }
    }
}
