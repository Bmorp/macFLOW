import SwiftUI
import AppKit

enum StandByClockStyle: Int, CaseIterable, Identifiable {
    case glass = 3, digital = 0, analog = 1, float = 2
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .glass: "Glass"
        case .digital: "Digital"
        case .analog: "Analog"
        case .float: "Float"
        }
    }
    /// Faces laid out like the lock screen — date above, time below — can tuck behind a wallpaper's foreground.
    var tucksBehindDepth: Bool { self != .analog }
}

enum StandByAccent: Int, CaseIterable, Identifiable {
    case white, red, orange, yellow, green, blue, purple
    var id: Int { rawValue }
    var color: Color {
        switch self {
        case .white: Color(white: 0.96)
        case .red: Color(red: 1.0, green: 0.27, blue: 0.23)
        case .orange: Color(red: 1.0, green: 0.62, blue: 0.04)
        case .yellow: Color(red: 1.0, green: 0.84, blue: 0.04)
        case .green: Color(red: 0.19, green: 0.82, blue: 0.35)
        case .blue: Color(red: 0.25, green: 0.6, blue: 1.0)
        case .purple: Color(red: 0.75, green: 0.45, blue: 1.0)
        }
    }
    var label: String {
        switch self {
        case .white: "White"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        }
    }
}

/// Where the clock sits on the screen, as fractions of its height. The wallpapers are composed around it: a calm
/// sky behind the time, and on the depth pictures a ridge that crosses the lower part of the digits.
enum ClockLayout {
    static let dateY: CGFloat = 0.135
    static let timeY: CGFloat = 0.385
    /// Point size of the numerals: their height runs from about 19 % to 58 % of the screen.
    static let timeSize: CGFloat = 0.55
    static let chipsY: CGFloat = 0.9
}

/// The clock page in two layers, so a wallpaper's foreground can sit between them: `.back` is the date and the time,
/// `.front` the row of chips at the bottom.
struct StandByClockPage: View {
    enum Layer { case back, front }

    let layer: Layer
    let size: CGSize
    /// The wallpaper, blurred and lifted, for the glass numerals (nil on black or at night).
    let frost: CGImage?
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var cal = CalendarModel.shared
    @ObservedObject private var weather = WeatherService.shared
    @ObservedObject private var battery = BatteryMonitor.shared

    private var accent: Color { (StandByAccent(rawValue: prefs.standByAccent) ?? .white).color }
    private var style: StandByClockStyle { StandByClockStyle(rawValue: prefs.standByClockStyle) ?? .glass }

    var body: some View {
        // Digits change once a minute; only the analog second hand needs every second.
        TimelineView(MinuteOrSecond(seconds: style == .analog && layer == .back)) { ctx in
            Group {
                switch (style, layer) {
                case (.analog, .back): analog(ctx.date)
                case (.analog, .front): Color.clear
                case (_, .back): lockScreen(ctx.date)
                case (_, .front): chipsRow(ctx.date)
                }
            }
            .frame(width: size.width, height: size.height)
        }
    }

    private func timeParts(_ date: Date) -> (String, String) {
        (date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted))), date.formatted(.dateTime.minute(.twoDigits)))
    }

    // MARK: Lock-screen faces (Glass, Digital, Float)

    private func lockScreen(_ date: Date) -> some View {
        let (h, m) = timeParts(date)
        return ZStack {
            dateLine(date)
                .position(x: size.width / 2, y: size.height * ClockLayout.dateY)
            Group {
                switch style {
                case .glass: GlassTime(hour: h, minute: m, size: size, frost: frost)
                case .float: solidTime(h, m, weight: .heavy, design: .rounded, minuteOpacity: 0.62)
                default: solidTime(h, m, weight: .semibold, design: .rounded, minuteOpacity: 1)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(date.formatted(date: .omitted, time: .shortened))
        }
    }

    /// The date, and the weather beside it when there is some — one quiet line, as on the lock screen.
    private func dateLine(_ date: Date) -> some View {
        HStack(spacing: size.height * 0.014) {
            Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
            if prefs.weatherEnabled, let w = weather.snapshot {
                HStack(spacing: size.height * 0.006) {
                    Image(systemName: WeatherService.symbol(w.code, day: w.isDay)).symbolRenderingMode(.multicolor)
                    Text("\(Int(w.temp.rounded()))°")
                }
            }
        }
        .font(.system(size: max(17, size.height * 0.03), weight: .semibold))
        .foregroundStyle(style == .glass ? Color.white.opacity(0.94) : accent)
        .shadow(color: .black.opacity(0.22), radius: 10, y: 1)
    }

    private func solidTime(_ h: String, _ m: String, weight: Font.Weight, design: Font.Design, minuteOpacity: Double) -> some View {
        let f = size.height * ClockLayout.timeSize * 0.92
        return HStack(spacing: 0) {
            Text(h).foregroundStyle(accent)
            Text(":").foregroundStyle(accent.opacity(0.55)).offset(y: -f * 0.06)
            Text(m).foregroundStyle(accent.opacity(minuteOpacity))
        }
        .font(.system(size: f, weight: weight, design: design).monospacedDigit())
        .contentTransition(.numericText())
        .animation(Motion.duo, value: m)
        .lineLimit(1)
        .minimumScaleFactor(0.5)
        .shadow(color: .black.opacity(0.22), radius: f * 0.05, y: f * 0.02)
        .frame(width: size.width * 0.94)
        .position(x: size.width / 2, y: size.height * ClockLayout.timeY)
    }

    /// What's next and whether it's charging, in small glass pills — only what there is.
    private func chipsRow(_ date: Date) -> some View {
        HStack(spacing: size.height * 0.012) {
            ForEach(chips(date).filter { $0.id != "weather" && ($0.id != "battery" || battery.isCharging || battery.level <= 20) }) { chip in
                chipView(chip)
                    .padding(.horizontal, size.height * 0.02)
                    .frame(height: max(32, size.height * 0.046))
                    .glassPill()
            }
        }
        .position(x: size.width / 2, y: size.height * ClockLayout.chipsY)
    }

    // MARK: Analog

    private func analog(_ date: Date) -> some View {
        HStack(spacing: size.width * 0.06) {
            let dial = size.height * 0.72
            AnalogClock(date: date, seconds: true, accent: accent == StandByAccent.white.color ? DS.Palette.orange : accent, ambient: true, drawsFace: false)
                .frame(width: dial, height: dial)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                .background { GlassDisc(diameter: dial) }
                .accessibilityLabel(date.formatted(date: .omitted, time: .shortened))
            VStack(alignment: .leading, spacing: size.height * 0.03) {
                Text(date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: max(17, size.height * 0.04), weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
                Text(date.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: size.height * 0.1, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: size.height * 0.018) {
                    ForEach(chips(date)) { chip in chipView(chip) }
                }
            }
            .shadow(color: .black.opacity(0.3), radius: 14, y: 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, size.width * 0.07)
    }

    // MARK: Chips

    private struct Chip: Identifiable {
        let id: String
        let symbol: String
        let text: String
        var tint: Color = .white
    }

    private func chips(_ date: Date) -> [Chip] {
        var list: [Chip] = []
        if let e = cal.events.first(where: { !$0.isAllDay && $0.end > date && Calendar.current.isDateInToday($0.start) }) {
            list.append(Chip(id: "event", symbol: "calendar", text: "\(e.title) · \(CalendarModel.relative(e))", tint: e.color))
        }
        if prefs.weatherEnabled, let w = weather.snapshot {
            list.append(Chip(id: "weather", symbol: WeatherService.symbol(w.code, day: w.isDay), text: "\(Int(w.temp.rounded()))° \(WeatherService.describe(w.code))"))
        }
        if battery.hasBattery {
            list.append(Chip(id: "battery", symbol: battery.isCharging ? "bolt.fill" : battery.symbol,
                             text: battery.isCharging ? "\(battery.level)% · Charging" : "\(battery.level)%",
                             tint: battery.isCharging ? DS.Palette.green : .white))
        }
        return list
    }

    private func chipView(_ chip: Chip) -> some View {
        HStack(spacing: 8) {
            Image(systemName: chip.symbol)
                .symbolRenderingMode(chip.id == "weather" ? .multicolor : .monochrome)
                .foregroundStyle(chip.tint)
            Text(chip.text).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
        }
        .font(.system(size: max(14, size.height * 0.02), weight: .semibold))
    }
}

// MARK: - Glass numerals

/// The time as SF Pro's own glyph outlines (condensed, semibold, tabular figures, a smaller colon centred on them),
/// laid out across a full-screen rect, so Liquid Glass can take their exact shape.
struct TimeShape: Shape {
    let hour: String
    let minute: String
    let fontSize: CGFloat

    func path(in rect: CGRect) -> Path { Path(TimeGlyphs.path(hour: hour, minute: minute, size: fontSize, in: rect)) }
}

enum TimeGlyphs {
    static func font(_ size: CGFloat) -> CTFont {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold, width: .condensed)
        let figures = base.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return (NSFont(descriptor: figures, size: size) ?? base) as CTFont
    }

    /// A string's outline in glyph space (y up from the baseline) and its advance.
    static func outline(_ s: String, _ font: CTFont) -> (CGPath, CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
        let path = CGMutablePath()
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let n = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: n), at = [CGPoint](repeating: .zero, count: n)
            CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: n), &at)
            let runFont = ((CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont?) ?? font
            for i in 0..<n {
                if let g = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
                    path.addPath(g, transform: CGAffineTransform(translationX: at[i].x, y: at[i].y))
                }
            }
        }
        return (path, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    static func path(hour: String, minute: String, size: CGFloat, in rect: CGRect) -> CGPath {
        let f = font(size), small = font(size * 0.72)
        let (hp, hw) = outline(hour, f), (cp, cw) = outline(":", small), (mp, mw) = outline(minute, f)
        let gap = size * 0.02
        let cap = CTFontGetCapHeight(f)
        var x = rect.minX + rect.width / 2 - (hw + cw + mw + gap * 2) / 2
        let baseline = rect.minY + rect.height * ClockLayout.timeY + cap / 2
        let out = CGMutablePath()
        // Glyph space is y-up; the view is y-down.
        func place(_ p: CGPath, dy: CGFloat = 0) { out.addPath(p, transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: x, ty: baseline + dy)) }
        place(hp); x += hw + gap
        place(cp, dy: cp.boundingBox.midY - cap / 2); x += cw + gap
        place(mp)
        return out
    }
}

/// Tall numerals in Liquid Glass: the picture behind bends through them and light catches their edges, as on the
/// iPhone's lock screen. Before macOS 26 (and in offscreen renders) they're frosted out of the wallpaper instead.
struct GlassTime: View {
    let hour: String
    let minute: String
    let size: CGSize
    let frost: CGImage?

    private var f: CGFloat { size.height * ClockLayout.timeSize }
    private var shape: TimeShape { TimeShape(hour: hour, minute: minute, fontSize: f) }

    var body: some View {
        Group {
            if #available(macOS 26.0, *), !RenderMode.snapshot {
                Color.clear
                    .frame(width: size.width, height: size.height)
                    .glassEffect(.clear.tint(.white.opacity(0.06)), in: shape)
            } else {
                frosted
            }
        }
        .animation(Motion.duo, value: minute)
    }

    private var frosted: some View {
        ZStack {
            fill.mask(shape)
            shape.fill(LinearGradient(colors: [.white.opacity(0.34), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom))
            // Light along the top edges: the figures minus themselves nudged down.
            ZStack {
                shape.fill(.white)
                shape.fill(.white).offset(y: f * 0.0065).blendMode(.destinationOut)
            }
            .compositingGroup()
            .blur(radius: f * 0.0012)
            .opacity(0.6)
        }
        .compositingGroup()
        .shadow(color: .black.opacity(0.22), radius: f * 0.04, y: f * 0.015)
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder private var fill: some View {
        if let frost {
            Image(decorative: frost, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                .frame(width: size.width, height: size.height)
                .scaleEffect(1.09)
                .clipped()
        } else {
            LinearGradient(colors: [Color(white: 0.98), Color(white: 0.78)], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// The analog face as a disc of glass.
struct GlassDisc: View {
    let diameter: CGFloat

    var body: some View {
        if #available(macOS 26.0, *), !RenderMode.snapshot {
            Color.clear.frame(width: diameter, height: diameter).glassEffect(.regular, in: Circle())
        } else {
            Circle().fill(.black.opacity(0.32))
                .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom), lineWidth: 1))
                .frame(width: diameter, height: diameter)
        }
    }
}

extension View {
    /// A small capsule of glass behind a label (a translucent capsule before macOS 26).
    @ViewBuilder func glassPill() -> some View {
        if #available(macOS 26.0, *), !RenderMode.snapshot {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(Capsule().fill(.black.opacity(0.32)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
        }
    }
}

struct MinuteOrSecond: TimelineSchedule {
    let seconds: Bool
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnyIterator<Date> {
        let step: TimeInterval = seconds ? 1 : 60
        var next = Date(timeIntervalSinceReferenceDate: (startDate.timeIntervalSinceReferenceDate / step).rounded(.down) * step)
        return AnyIterator {
            defer { next += step }
            return next
        }
    }
}
