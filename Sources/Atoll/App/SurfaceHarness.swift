#if DEBUG
import AppKit
import SwiftUI

/// Debug-only: renders widgets, StandBy and the Dock surfaces offscreen with demo data.
@MainActor
enum SurfaceHarness {
    static func run(outDir: String) {
        Storage.readOnly = true
        RenderMode.snapshot = true
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        seed()

        let boardA: [WidgetKind] = [.nowPlaying, .upNext, .weather, .worldClock, .batteries]
        let boardB: [WidgetKind] = [.timer, .reminders, .system, .shortcuts, .shelf]
        for (scheme, tag) in [(ColorScheme.light, "light"), (.dark, "dark")] {
            render(board(boardA, style: .desktop), scheme: scheme, name: "60-widgets-a-\(tag)", outDir: outDir)
            render(board(boardB, style: .desktop), scheme: scheme, name: "61-widgets-b-\(tag)", outDir: outDir)
        }
        render(vibrantBoard(), scheme: .light, name: "62-widgets-vibrant-light", outDir: outDir)
        render(vibrantBoard(), scheme: .dark, name: "63-widgets-vibrant-dark", outDir: outDir)
        render(promptBoard(), scheme: .light, name: "64-widgets-empty-states", outDir: outDir)
        FocusTimer.shared.start(minutes: 25, label: "Focus")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        render(board([.timer], style: .desktop), scheme: .dark, name: "65-widget-timer-running", outDir: outDir)
        FocusTimer.shared.stop()

        standBy(outDir: outDir)

        render(dockScene(), scheme: .dark, name: "80-dock-companion", outDir: outDir)
        render(dropScene(), scheme: .dark, name: "81-dock-drop-tray", outDir: outDir)
        renderLive(WidgetGalleryView(), size: CGSize(width: 880, height: 540), name: "82-widget-gallery", outDir: outDir)
        renderLive(Form { WidgetsPane() }.formStyle(.grouped), size: CGSize(width: 540, height: 470), name: "83-settings-widgets", outDir: outDir, plain: true)
        renderLive(StandByPane(), size: CGSize(width: 640, height: 1180), name: "84-settings-standby", outDir: outDir, plain: true)
        renderLive(DockPane(), size: CGSize(width: 540, height: 400), name: "85-settings-dock", outDir: outDir, plain: true)
        print("surfaces ok → \(outDir)")
    }

    // MARK: StandBy

    /// `--standby <dir>`: only StandBy and its settings (`ATOLL_ONLY=glass,lyrics` narrows it further).
    static func runStandBy(outDir: String) {
        Storage.readOnly = true
        RenderMode.snapshot = true
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        seed()
        let only = ProcessInfo.processInfo.environment["ATOLL_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        standBy(outDir: outDir, only: only)
        if only == nil || only!.contains("settings") {
            renderLive(StandByPane(), size: CGSize(width: 640, height: 1180), name: "84-settings-standby", outDir: outDir, plain: true)
        }
        print("standby ok → \(outDir)")
    }

    /// Every StandBy page at a MacBook Air's size, on the real wallpapers when they're in the repo.
    static func standBy(outDir: String, only: Set<String>? = nil) {
        let screen = CGSize(width: 1470, height: 956)
        let first = Wallpapers.available.first?.id ?? Wallpapers.none
        let depth = Wallpapers.available.first(where: \.hasDepth)?.id ?? first
        func shot(_ name: String, _ page: StandByModel.Page, style: StandByClockStyle = .glass, wallpaper: String,
                  night: Bool = false, accent: StandByAccent = .white, scale: CGFloat = 1) {
            guard only == nil || only!.contains(where: { name.contains($0) }) else { return }
            Prefs.shared.standByClockStyle = style.rawValue
            Prefs.shared.standByAccent = accent.rawValue
            Prefs.shared.standByWallpaper = wallpaper
            let model = StandByModel()
            model.prepare(screen: screen, scale: scale)
            RunLoop.main.run(until: Date().addingTimeInterval(0.9))
            model.page = page
            model.night = night
            model.chromeVisible = true
            model.showHint = name.contains("hint")
            render(StandByView(model: model).frame(width: screen.width, height: screen.height), scheme: .dark, scale: scale, name: name, outDir: outDir)
        }
        Prefs.shared.standByDepth = true
        Prefs.shared.standByLyrics = true
        shot("70-standby-glass-hint", .clock, wallpaper: depth, scale: 2)
        for w in Wallpapers.available { shot("70-standby-glass-\(w.id)", .clock, wallpaper: w.id) }
        shot("71-standby-analog", .clock, style: .analog, wallpaper: first)
        shot("72-standby-float", .clock, style: .float, wallpaper: depth, accent: .orange)
        shot("72-standby-digital", .clock, style: .digital, wallpaper: depth)
        shot("72-standby-glass-black", .clock, wallpaper: Wallpapers.none)
        shot("73-standby-widgets", .widgets, wallpaper: first)

        LyricsModel.shared.debugSet(demoLyrics)
        // Mid-verse, then in the instrumental break.
        NowPlayingModel.shared.debugInject(title: "Midnight City", artist: "M83", duration: 243, elapsed: 76, artwork: demoCover())
        shot("74-standby-lyrics", .nowPlaying, wallpaper: first, scale: 2)
        NowPlayingModel.shared.debugInject(title: "Midnight City", artist: "M83", duration: 243, elapsed: 58, artwork: demoCover())
        shot("74-standby-lyrics-gap", .nowPlaying, wallpaper: first)
        NowPlayingModel.shared.debugInject(title: "Midnight City", artist: "M83", duration: 243, elapsed: 80, artwork: demoArtwork(), playing: false)
        shot("74-standby-lyrics-paused", .nowPlaying, wallpaper: first)
        LyricsModel.shared.debugSet(Lyrics.plain(demoLyrics.lines.map(\.text).joined(separator: "\n"), source: "music"))
        NowPlayingModel.shared.debugInject(title: "Midnight City", artist: "M83", duration: 243, elapsed: 97, artwork: demoArtwork())
        shot("74-standby-lyrics-plain", .nowPlaying, wallpaper: first)
        LyricsModel.shared.debugSet(nil)
        shot("74-standby-nowplaying", .nowPlaying, wallpaper: first)
        shot("75-standby-night", .clock, wallpaper: depth, night: true)
        Prefs.shared.standByClockStyle = StandByClockStyle.glass.rawValue
        Prefs.shared.standByAccent = 0
        Prefs.shared.standByWallpaper = Wallpapers.shuffle
    }

    /// A square from one of the wallpapers: a cover with real colour in it, for the album backdrop.
    static func demoCover() -> NSImage {
        let id = ProcessInfo.processInfo.environment["ATOLL_COVER"] ?? "silk"
        guard let url = Wallpapers.url(id) ?? Wallpapers.available.first.flatMap({ Wallpapers.url($0.id) }),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: 1000] as CFDictionary) else { return demoArtwork() }
        let side = min(cg.width, cg.height)
        guard let square = cg.cropping(to: CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)) else { return demoArtwork() }
        return NSImage(cgImage: square, size: NSSize(width: 300, height: 300))
    }

    /// Original placeholder lines (not any real song's), timed like a track: an intro, verses, an instrumental break.
    static let demoLyrics: Lyrics = {
        let text = [
            "Neon on the water", "Every window holding light", "We were never going home tonight",
            "Engines in the distance", "Singing through the overpass", "Count the seconds as they pass",
            "", "Turn the radio louder", "Let the skyline pull us in", "Every ending is a place to begin",
            "Running through the static", "Chasing colours down the line", "Hold the moment, it is mine",
        ]
        var t = 0.0
        let times = text.indices.map { i -> Double in
            t = i == 0 ? 22 : t + (text[i - 1].isEmpty ? 18 : 4.6)
            return t
        }
        let lrc = zip(times, text).map { String(format: "[%02d:%05.2f] %@", Int($0) / 60, $0.truncatingRemainder(dividingBy: 60), $1) }.joined(separator: "\n")
        return Lyrics.synced(lrc: lrc, source: "demo")!
    }()

    // MARK: Data

    private static func seed() {
        let now = Date()
        let cal = Calendar.current
        func at(_ h: Int, _ m: Int, dayOffset: Int = 0) -> Date {
            let d = cal.date(byAdding: .day, value: dayOffset, to: now) ?? now
            return cal.date(bySettingHour: h, minute: m, second: 0, of: d) ?? now
        }
        CalendarModel.shared.debugSet([
            .init(id: "1", title: "Design Review", start: now.addingTimeInterval(8 * 60), end: now.addingTimeInterval(38 * 60), isAllDay: false,
                  color: DS.Palette.indigo, location: nil, meetingURL: URL(string: "https://zoom.us/j/1")),
            .init(id: "2", title: "Lunch with Maya", start: now.addingTimeInterval(95 * 60), end: now.addingTimeInterval(155 * 60), isAllDay: false,
                  color: DS.Palette.orange, location: "Café Rio", meetingURL: nil),
            .init(id: "3", title: "Atoll 4 Planning", start: now.addingTimeInterval(4 * 3600), end: now.addingTimeInterval(5 * 3600), isAllDay: false,
                  color: DS.Palette.green, location: nil, meetingURL: URL(string: "https://meet.google.com/abc")),
            .init(id: "4", title: "Gym", start: now.addingTimeInterval(6 * 3600), end: now.addingTimeInterval(7 * 3600), isAllDay: false,
                  color: DS.Palette.red, location: nil, meetingURL: nil),
            .init(id: "5", title: "Standup", start: at(9, 30, dayOffset: 1), end: at(9, 45, dayOffset: 1), isAllDay: false,
                  color: DS.Palette.blue, location: nil, meetingURL: URL(string: "https://zoom.us/j/2")),
        ])
        RemindersService.shared.debugSet([
            .init(id: "r1", title: "Send the invoice to Northwave", due: now.addingTimeInterval(-86_400 * 2), color: DS.Palette.blue, done: false),
            .init(id: "r2", title: "Call Sam about the launch", due: at(17, 0), color: DS.Palette.orange, done: false),
            .init(id: "r3", title: "Book flights to Lisbon", due: nil, color: DS.Palette.blue, done: true),
            .init(id: "r4", title: "Renew passport", due: at(10, 0, dayOffset: 3), color: DS.Palette.red, done: false),
            .init(id: "r5", title: "Pick up dry cleaning", due: nil, color: DS.Palette.green, done: false),
        ])
        ShortcutsService.shared.debugSet(["Morning Routine", "Resize Images", "Log Water", "Focus Mode", "Share Screenshot", "Text Last Image", "Play Focus Mix", "Home Lights Off"])
        ShelfModel.shared.clear()
        ShelfModel.shared.add(urls: ["/System/Applications/Calculator.app", "/System/Applications/Notes.app", "/private/etc/hosts"].map { URL(fileURLWithPath: $0) })
        RecentFiles.shared.debugSet(["/System/Applications/Notes.app", "/private/etc/hosts", "/System/Library/Desktop Pictures", "/private/etc/zshrc"].map {
            FileHit(id: $0, name: ($0 as NSString).lastPathComponent, contentType: nil, modified: now, size: nil)
        })
        Prefs.shared.weatherEnabled = true
        let hours = (1...6).map { i in
            WeatherService.Hour(time: now.addingTimeInterval(Double(i) * 3600), temp: 29 - Double(i) * 0.7, code: [2, 2, 3, 61, 80, 3][i - 1], isDay: true)
        }
        WeatherService.shared.debugSet(.init(temp: 28, code: 2, isDay: true, high: 31, low: 24, place: "Kochi", updated: now, hours: hours, fahrenheit: false))
        NowPlayingModel.shared.debugInjectApp(nil)
        NowPlayingModel.shared.debugInject(title: "Midnight City", artist: "M83", duration: 243, elapsed: 97, artwork: demoArtwork())
        SystemStats.shared.start()
        RunLoop.main.run(until: Date().addingTimeInterval(2.4))
    }

    // MARK: Scenes

    private static let wallpaper = LinearGradient(
        colors: [Color(red: 0.26, green: 0.42, blue: 0.62), Color(red: 0.58, green: 0.46, blue: 0.62), Color(red: 0.86, green: 0.6, blue: 0.5)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    private static func widget(_ kind: WidgetKind, _ family: WidgetFamily, style: WidgetStyle, editing: Bool = false) -> some View {
        WidgetContainer(kind: kind, family: family, editing: editing, onRemove: {}) { WidgetContent(kind: kind) }
            .environment(\.widgetStyle, style)
    }

    private static func board(_ kinds: [WidgetKind], style: WidgetStyle) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            ForEach(kinds) { kind in
                HStack(alignment: .top, spacing: 20) {
                    ForEach(kind.families) { family in widget(kind, family, style: style) }
                }
            }
        }
        .padding(28)
        .background(wallpaper)
    }

    private static func vibrantBoard() -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 20) {
                widget(.worldClock, .small, style: .vibrant)
                widget(.weather, .small, style: .vibrant)
                widget(.system, .small, style: .vibrant)
            }
            HStack(alignment: .top, spacing: 20) {
                widget(.nowPlaying, .medium, style: .vibrant)
                widget(.upNext, .small, style: .vibrant, editing: true)
            }
        }
        .padding(28)
        .background(wallpaper)
    }

    private static func promptBoard() -> some View {
        HStack(alignment: .top, spacing: 20) {
            WidgetContainer(kind: .weather, family: .small) {
                WidgetPrompt(symbol: "cloud.sun.fill", message: "See the weather where you are.", action: "Turn On", tint: DS.Palette.blue) {}
            }
            WidgetContainer(kind: .upNext, family: .medium) {
                WidgetPrompt(symbol: "calendar", message: "See your next meeting and join it in one click.", action: "Allow Access", tint: DS.Palette.red) {}
            }
        }
        .environment(\.widgetStyle, .desktop)
        .padding(28)
        .background(wallpaper)
    }

    private static func fakeDock(width: CGFloat) -> some View {
        HStack(spacing: 10) {
            ForEach(["com.apple.finder", "com.apple.Safari", "com.apple.mail", "com.apple.Music", "com.apple.Notes", "com.apple.systempreferences"], id: \.self) { id in
                if let icon = IconCache.app(bundleID: id) { IconImage(image: icon, size: 48) }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.22)))
    }

    private static func dockScene() -> some View {
        let model = DockBarModel()
        model.shown = true
        FocusTimer.shared.start(minutes: 25, label: "Focus")
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        model.pointer = CGPoint(x: 236, y: 30)
        let view = VStack(spacing: 0) {
            Spacer()
            DockBarView(model: model)
            fakeDock(width: 420).padding(.bottom, 6)
        }
        .frame(width: 1100, height: 330)
        .background(wallpaper)
        return view
    }

    private static func dropScene() -> some View {
        FocusTimer.shared.stop()
        let model = DockDropModel()
        model.shown = true
        return VStack(spacing: 0) {
            Spacer()
            DockDropTrayView(model: model)
            fakeDock(width: 420).padding(.bottom, 6)
        }
        .frame(width: 760, height: 260)
        .background(wallpaper)
    }

    // MARK: Rendering

    private static func render<V: View>(_ view: V, scheme: ColorScheme, scale: CGFloat = 2, name: String, outDir: String) {
        let r = ImageRenderer(content: view.environment(\.colorScheme, scheme))
        r.scale = scale
        r.colorMode = .nonLinear
        guard let cg = r.cgImage else { print("render failed: \(name)"); return }
        try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
            .write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png"))
    }

    private static func renderLive<V: View>(_ view: V, size: CGSize, name: String, outDir: String, plain: Bool = false) {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: plain ? [.titled] : [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = !plain
        win.contentView = host
        win.appearance = NSAppearance(named: .aqua)
        win.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        win.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png"))
        win.orderOut(nil)
    }

    static func demoArtwork() -> NSImage {
        let img = NSImage(size: NSSize(width: 300, height: 300))
        img.lockFocus()
        NSGradient(colors: [NSColor(red: 0.98, green: 0.45, blue: 0.3, alpha: 1), NSColor(red: 0.55, green: 0.2, blue: 0.85, alpha: 1)])?
            .draw(in: NSRect(x: 0, y: 0, width: 300, height: 300), angle: -45)
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(ovalIn: NSRect(x: 90, y: 90, width: 120, height: 120)).fill()
        img.unlockFocus()
        return img
    }
}
#endif
