#if DEBUG
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Film-only: renders island states and transitions as transparent frames for the promo film.
/// Same springs, shapes, rim sweep and content as the live island; demo data only.
@MainActor
enum FilmHarness {
    static var active = false
    nonisolated(unsafe) static var isActive = false
    static var out = URL(fileURLWithPath: "/tmp")
    static var geo: NotchGeometry!
    static let scale: CGFloat = CGFloat(Double(ProcessInfo.processInfo.environment["FILM_SCALE"] ?? "3") ?? 3)
    static var manifest: [[String: Any]] = []

    static let openSpring = Spring(response: 0.3, dampingRatio: 0.8)
    static let closeSpring = Spring(response: 0.26, dampingRatio: 1)
    static let morphSpring = Spring(response: 0.3, dampingRatio: 0.88)
    static let splitSpring = Spring(response: 0.45, dampingRatio: 0.72)

    // MARK: Demo data

    static var art: NSImage = NSImage()
    static var facetime: AudioApp!
    static var meeting: CalendarModel.Event!
    static var call: ActivityCenter.Call?

    struct Snap {
        let model: IslandModel
        let spec: IslandSpec
        let rim: RimStyle
        let rimStrength: Double
        let mode: IslandMode
        let alert: AlertState?
        let primary: ActivityKind?
        let isOpen: Bool
        let secondary: ActivityKind?
    }

    struct Bubble {
        var progress: CGFloat
        var content: CGFloat
    }

    static func spin(_ t: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    static func setLive(_ list: [ActivityKind]) {
        ActivityCenter.shared.debugSet(list, meeting: meeting, call: call)
        spin(0.06)
    }

    static func snap(_ mode: IslandMode = .compact, alert: IslandAlert? = nil, prep: ((IslandModel) -> Void)? = nil) -> Snap {
        let m = IslandModel(geometry: geo, isPrimary: true)
        spin(0.05)
        m.debugSetMode(mode, alert: alert)
        prep?(m)
        spin(0.12)
        return capture(m)
    }

    static func capture(_ m: IslandModel) -> Snap {
        Snap(model: m, spec: m.spec, rim: m.rim, rimStrength: m.rimStrength, mode: m.mode, alert: m.alert,
             primary: m.primary, isOpen: m.isOpen, secondary: m.secondary)
    }

    // MARK: Frame

    private static func lerp(_ a: CGFloat, _ b: CGFloat, _ p: CGFloat) -> CGFloat { a + (b - a) * p }

    static func sweepAt(_ time: Double, opening: Bool) -> CGFloat {
        guard opening else { return 1 }
        let s = max(0, time - 0.05) / 0.6
        return CGFloat(min(1, s < 0.5 ? 2 * s * s : 1 - pow(-2 * s + 2, 2) / 2))
    }

    static func frame(_ a: Snap, _ b: Snap, g: CGFloat, time: Double, sweep: CGFloat, bubble: Bubble?) -> some View {
        let sa = a.spec, sb = b.spec
        let spec = IslandSpec(size: CGSize(width: lerp(sa.size.width, sb.size.width, g), height: lerp(sa.size.height, sb.size.height, g)),
                              shoulder: lerp(sa.shoulder, sb.shoulder, g), corner: lerp(sa.corner, sb.corner, g))
        let rim = lerp(CGFloat(a.rimStrength), CGFloat(b.rimStrength), min(1, max(0, g)))
        let showFrom = a.isOpen && !b.isOpen && time < Motion.closeSwap
        let shown = showFrom ? a : b
        let canvas = IslandModel.maxCanvas(for: geo)
        let notchH = geo.notchSize.height
        let host = b.secondary != nil ? b : a
        return ZStack(alignment: .top) {
            if let k = host.secondary, let bub = bubble {
                let d = host.model.bubbleDiameter
                ZStack(alignment: .top) {
                    LiquidSplit(islandWidth: host.model.compactSize.width, height: notchH, diameter: d,
                                restOffset: host.model.bubbleOffset, progress: bub.progress)
                        .frame(height: notchH + 12)
                    ActivityMinimal(kind: k, diameter: d)
                        .offset(x: host.model.bubbleOffset)
                        .opacity(Double(min(1, max(0, bub.content))))
                        .scaleEffect(0.5 + 0.5 * bub.content)
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
            IslandSurface(spec: spec, notchHeight: notchH, rim: b.rim, rimStrength: Double(rim), sweep: sweep,
                          elevated: b.isOpen || a.isOpen) {
                IslandPresentation(model: shown.model, mode: shown.mode, size: shown.spec.size, alert: shown.alert,
                                   primary: shown.primary, ns: Namespace().wrappedValue)
            }
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Output

    static func save(_ rep: NSBitmapImageRep, _ dir: URL, _ i: Int) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(String(format: "%04d.png", i)))
    }

    static func render<V: View>(_ v: V, size: CGSize, live: Bool, dir: URL, index: Int) {
        if !live {
            let r = ImageRenderer(content: v)
            r.scale = scale
            r.isOpaque = false
            r.colorMode = .nonLinear
            if let cg = r.cgImage { save(NSBitmapImageRep(cgImage: cg), dir, index) }
            return
        }
        // Scroll views and text fields only draw inside a real window. A 2× backing scaled by 1.5 gives 3×.
        let k: CGFloat = scale / 2
        let root = v.scaleEffect(k, anchor: .topLeading).frame(width: size.width * k, height: size.height * k, alignment: .topLeading)
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: CGSize(width: size.width * k, height: size.height * k))
        let win = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.contentView = host
        win.setFrameOrigin(NSPoint(x: -12000, y: -12000))
        win.orderFrontRegardless()
        spin(0.45)
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            save(rep, dir, index)
        }
        win.orderOut(nil)
    }

    static func record(_ name: String, times: [Double], live: Bool, note: String) {
        let canvas = IslandModel.maxCanvas(for: geo)
        manifest.append(["name": name, "frames": times.count, "times": times, "live": live, "note": note,
                         "canvas": [canvas.width, canvas.height], "scale": scale, "notch": [geo.notchSize.width, geo.notchSize.height]])
        print("  \(name): \(times.count) frames")
    }

    /// A spring transition from `a` to `b`, sampled at `times` (seconds of real spring time).
    static func transition(_ name: String, _ a: Snap, _ b: Snap, spring: Spring, times: [Double], live: Bool = false,
                           sweep opening: Bool? = nil, bubble: ((Double) -> Bubble?)? = nil, each: ((Int, Double) -> Void)? = nil) {
        let dir = out.appendingPathComponent(name)
        let opens = opening ?? (b.isOpen && (!a.isOpen || a.mode != b.mode))
        let canvas = IslandModel.maxCanvas(for: geo)
        for (i, t) in times.enumerated() {
            each?(i, t)
            let g = CGFloat(t <= 0 ? 0 : spring.value(target: 1.0, time: t))
            let v = frame(a, b, g: g, time: t, sweep: sweepAt(t, opening: opens), bubble: bubble?(t))
            render(v, size: canvas, live: live, dir: dir, index: i)
        }
        record(name, times: times, live: live, note: "transition")
    }

    /// One state held while its content changes: `each` updates demo data before frame `i`.
    static func hold(_ name: String, _ s: Snap, count: Int, live: Bool = false, bubble: Bubble? = nil, each: ((Int) -> Void)? = nil) {
        let dir = out.appendingPathComponent(name)
        let canvas = IslandModel.maxCanvas(for: geo)
        for i in 0..<count {
            each?(i)
            spin(0.05)
            let now = capture(s.model)
            let v = frame(now, now, g: 1, time: 1, sweep: 1, bubble: bubble)
            render(v, size: canvas, live: live, dir: dir, index: i)
        }
        record(name, times: (0..<count).map { Double($0) }, live: live, note: "hold")
    }

    static func samples(_ duration: Double, fps: Double) -> [Double] {
        let n = Int((duration * fps).rounded())
        return (0...n).map { Double($0) / fps }
    }

    // MARK: Run

    static func run(outDir: String) {
        active = true
        isActive = true
        Storage.readOnly = true
        RenderMode.snapshot = true
        out = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let screen = NSScreen.screens.first(where: \.hasNotch) ?? NSScreen.main!
        geo = NotchGeometry.detect(for: screen)
        let only = ProcessInfo.processInfo.environment["FILM_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        func want(_ n: String) -> Bool { only == nil || only!.contains(n) }

        art = ProcessInfo.processInfo.environment["ATOLL_ART"].flatMap { NSImage(contentsOfFile: $0) } ?? NSImage()
        facetime = AudioApp(id: "com.apple.FaceTime", name: "FaceTime",
                            url: NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FaceTime"))
        meeting = CalendarModel.Event(id: "m1", title: "Design Review", start: Date().addingTimeInterval(4 * 60 + 40),
                                      end: Date().addingTimeInterval(34 * 60), isAllDay: false, color: DS.Palette.indigo,
                                      location: nil, meetingURL: URL(string: "https://facetime.apple.com/join#v=1&p=demo"))
        ClaudeSessions.shared.debugSet([
            ClaudeSessions.Session(id: "a", pid: 1, name: "Refactor the settings window", folder: "Mac Flow", cwd: "/x/Mac Flow", state: .working,
                                   since: Date().addingTimeInterval(-196), viaDesktop: true),
            ClaudeSessions.Session(id: "b", pid: 2, name: "Write the release notes", folder: "Mac Flow", cwd: "/x/Mac Flow", state: .idle,
                                   since: Date().addingTimeInterval(-1500), viaDesktop: true),
            ClaudeSessions.Session(id: "c", pid: 3, name: "Fix the flaky tests", folder: "Mac Flow", cwd: "/x/Mac Flow", state: .idle,
                                   since: Date().addingTimeInterval(-7200), viaDesktop: true),
        ])
        Prefs.shared.weatherEnabled = true
        WeatherService.shared.debugSet(.init(temp: 24, code: 1, isDay: true, high: 27, low: 18, place: "Cupertino", updated: Date(), hours: [], fahrenheit: false))
        ShelfModel.shared.clear()
        spin(0.6)

        func track(_ elapsed: Double = 97) {
            NowPlayingModel.shared.debugInjectApp(nil)
            NowPlayingModel.shared.debugInject(title: "Midnight City", artist: "M83", duration: 243, elapsed: elapsed, artwork: art)
        }
        func silence() {
            NowPlayingModel.shared.debugInjectApp(nil)
            NowPlayingModel.shared.debugInject(title: "", artist: "", duration: 0, elapsed: 0, artwork: nil, playing: false)
        }
        func timer(_ remaining: Double) {
            if !FocusTimer.shared.isActive { FocusTimer.shared.start(minutes: 25, label: "Focus") }
            FocusTimer.shared.debugFreeze(remaining: remaining)
        }
        func build(_ p: Double, done: Bool = false) {
            let files = Int((p * 880).rounded())
            CustomActivity.shared.debugSet(done
                ? CustomActivity.Item(title: "Build succeeded", detail: "Mac Flow · 880 files", symbol: "checkmark", tint: DS.Palette.indigo,
                                      progress: 1, state: .done, updated: Date())
                : CustomActivity.Item(title: "Building Mac Flow", detail: "Compiling \(files) of 880 files", symbol: "hammer.fill",
                                      tint: DS.Palette.indigo, progress: p, state: .running, updated: Date()))
        }
        func airpods(_ k: Double) -> IslandAlert {
            .device(.init(name: "AirPods Pro", symbol: "airpodspro", single: nil, left: Int(92 * k), right: Int(88 * k),
                          caseLevel: Int(64 * k), connected: true))
        }
        let fps30 = { (d: Double) in samples(d, fps: 30) }
        let fps60 = { (d: Double) in samples(d, fps: 60) }

        print("film: notch \(geo.notchSize), canvas \(IslandModel.maxCanvas(for: geo))")

        // 1. The notch, then a song wakes it.
        if want("wake") || want("notch") || want("expandMusic") || want("musicHold") {
            silence(); setLive([])
            let idle = snap()
            hold("notch", idle, count: 1)
            track(); setLive([.nowPlaying])
            let compact = snap()
            transition("wake", idle, compact, spring: openSpring, times: fps60(0.6))
            let open = snap(.expanded(.activity(.nowPlaying)))
            transition("expandMusic", compact, open, spring: openSpring, times: fps60(0.8))
            hold("musicHold", open, count: 4) { i in track(97 + Double(i)) }
        }

        // 2. A meeting: hover opens it, Join starts the call.
        if want("meeting") {
            track()
            call = ActivityCenter.Call(app: facetime, since: Date(), camera: true)
            setLive([.meeting])
            let compact = snap()
            hold("meetingCompact", compact, count: 1)
            let open = snap(.expanded(.activity(.meeting)))
            transition("expandMeeting", compact, open, spring: openSpring, times: fps30(0.6))
            setLive([.call, .meeting])
            let openM = snap(.expanded(.activity(.meeting)))
            let openC = snap(.expanded(.activity(.call)))
            transition("meetingToCall", openM, openC, spring: morphSpring, times: fps30(0.6)) { _, _ in
                call = ActivityCenter.Call(app: facetime, since: Date(), camera: true)
                ActivityCenter.shared.debugSet([.call, .meeting], meeting: meeting, call: call)
            }
            hold("callTick", openC, count: 4) { i in
                call = ActivityCenter.Call(app: facetime, since: Date().addingTimeInterval(-Double(i)), camera: true)
                ActivityCenter.shared.debugSet([.call, .meeting], meeting: meeting, call: call)
            }
            setLive([.call])
            let openC2 = snap(.expanded(.activity(.call)))
            let compactC = snap()
            transition("callClose", openC2, compactC, spring: closeSpring, times: fps30(0.5))
        }

        // 3. Flow: asked for a focus and music, it starts both — and the island splits.
        if want("flow") {
            silence(); call = nil; setLive([])
            let idle = snap()
            BrainAgent.shared.reset()
            BrainAgent.shared.draft = ""
            let brain0 = snap(.expanded(.brain))
            transition("openFlow", idle, brain0, spring: openSpring, times: fps30(0.6), live: true)
            let ask = "Focus for 25 minutes and play some music"
            let steps = stride(from: 0, through: ask.count, by: 2).map { $0 } + [ask.count]
            hold("flowType", brain0, count: steps.count, live: true) { i in
                BrainAgent.shared.draft = String(ask.prefix(steps[i]))
            }
            BrainAgent.shared.draft = ""
            let you = BrainAgent.Message(role: .you, text: ask)
            let a1 = BrainAgent.Message(role: .action, text: "Playing Midnight City", symbol: "music.note")
            let a2 = BrainAgent.Message(role: .action, text: "Started a 25-minute Focus timer", symbol: "timer")
            let reply = "Done. Your focus has started and the music is on — I’ll keep the notch quiet until it ends."
            var frames: [[BrainAgent.Message]] = [[you], [you, a1], [you, a1, a2]]
            let words = reply.split(separator: " ").map(String.init)
            for n in stride(from: 2, through: words.count, by: 2) {
                frames.append([you, a1, a2, BrainAgent.Message(role: .atoll, text: words.prefix(n).joined(separator: " "))])
            }
            frames.append([you, a1, a2, BrainAgent.Message(role: .atoll, text: reply)])
            hold("flowChat", brain0, count: frames.count, live: true) { i in BrainAgent.shared.debugSet(frames[i]) }

            track(); timer(1500); setLive([.timer, .nowPlaying])
            let brain1 = snap(.expanded(.brain))
            let compact = snap()
            transition("flowClose", brain1, compact, spring: closeSpring, times: fps30(0.5), live: true)
            transition("split", compact, compact, spring: splitSpring, times: fps60(1.3)) { t in
                Bubble(progress: CGFloat(splitSpring.value(target: 1.0, time: t)),
                       content: CGFloat(t <= 0.1 ? 0 : splitSpring.value(target: 1.0, time: t - 0.1)))
            }
            hold("splitTick", compact, count: 4, bubble: Bubble(progress: 1, content: 1)) { i in timer(1499 - Double(i)) }
        }

        // 4. A build reports in, races to done.
        if want("build") {
            silence(); FocusTimer.shared.stop(); build(0.24); setLive([.custom])
            let compact = snap()
            let open = snap(.expanded(.activity(.custom)))
            transition("expandBuild", compact, open, spring: openSpring, times: fps30(0.6))
            let n = 46
            hold("buildRun", open, count: n) { i in
                let x = Double(i) / Double(n - 1)
                build(0.24 + 0.76 * (1 - pow(1 - x, 1.6)))
            }
            build(1, done: true)
            let done = snap(.expanded(.activity(.custom)))
            transition("buildDone", open, done, spring: morphSpring, times: fps30(0.4), sweep: true)
            setLive([])
            let idle = snap()
            setLive([.custom])
            let done2 = snap(.expanded(.activity(.custom)))
            transition("buildClose", done2, idle, spring: closeSpring, times: fps30(0.5))
            // From the split timer + music straight into the build: the bubble melts back as the island opens.
            track(); timer(1496); build(0.24); setLive([.timer, .nowPlaying, .custom])
            let split = snap()
            let open2 = snap(.expanded(.activity(.custom)))
            transition("splitToBuild", split, open2, spring: openSpring, times: fps30(0.6)) { t in
                let g = CGFloat(max(0, 1 - t / 0.12))
                return Bubble(progress: g, content: g * g)
            }
            FocusTimer.shared.stop()
        }

        // 5. AirPods connect.
        if want("airpods") {
            silence(); setLive([])
            let idle = snap()
            let full = snap(.alert, alert: airpods(1))
            transition("airpodsOpen", idle, full, spring: openSpring, times: fps30(0.6))
            hold("airpodsHold", full, count: 1)
            transition("airpodsClose", full, idle, spring: closeSpring, times: fps30(0.5))
        }

        // 6. Drop a file on the notch.
        if want("drop") {
            silence(); setLive([])
            let idle = snap()
            let drop = snap(.drop)
            transition("dropOpen", idle, drop, spring: openSpring, times: fps30(0.6))
            let target = snap(.drop) { $0.dropTarget = .shelf }
            hold("dropTarget", target, count: 1)
            let file = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FILM_DOC"] ?? "/System/Applications/Notes.app")
            ShelfModel.shared.clear()
            ShelfModel.shared.add(urls: [file])
            setLive([.shelf])
            spin(1.0)
            let shelf = snap()
            transition("dropToShelf", target, shelf, spring: closeSpring, times: fps30(0.5))
            hold("shelfCompact", shelf, count: 1)
            ShelfModel.shared.clear()
        }

        // 7. Montage: every presentation, morphing at 2× speed.
        if want("montage") {
            struct M { let live: [ActivityKind]; let mode: IslandMode; let alert: IslandAlert?; let prep: () -> Void }
            let claudeDone = IslandAlert.claudeFinished(id: "a", name: "Refactor the settings window", duration: 734)
            let states: [M] = [
                M(live: [.nowPlaying], mode: .compact, alert: nil) { track() },
                M(live: [], mode: .alert, alert: airpods(1)) { silence() },
                M(live: [.call], mode: .compact, alert: nil) { call = ActivityCenter.Call(app: facetime, since: Date().addingTimeInterval(-754), camera: true) },
                M(live: [.download], mode: .expanded(.activity(.download)), alert: nil) {
                    DownloadsWatcher.shared.debugSet(.init(name: "Xcode_27.xip", progress: 0.62, bytes: 2_100_000_000)) },
                M(live: [], mode: .alert, alert: .charging(76)) {},
                M(live: [.meeting], mode: .compact, alert: nil) {},
                M(live: [], mode: .alert, alert: .volume(level: 0.62, muted: false)) {},
                M(live: [], mode: .alert, alert: claudeDone) {},
                M(live: [.timer, .nowPlaying], mode: .compact, alert: nil) { track(); timer(1312) },
                M(live: [.claude], mode: .compact, alert: nil) { FocusTimer.shared.stop() },
                M(live: [.nowPlaying], mode: .alert, alert: .trackChanged) { track() },
                M(live: [.nowPlaying], mode: .compact, alert: nil) { track() },
            ]
            for i in 0..<(states.count - 1) {
                let s = states[i], t = states[i + 1]
                s.prep(); t.prep()
                setLive(s.live)
                let a = snap(s.mode, alert: s.alert)
                setLive(t.live)
                let b = snap(t.mode, alert: t.alert)
                let times = (0..<8).map { Double($0) / 15 }
                let bub: ((Double) -> Bubble?)?
                if a.secondary != nil && b.secondary != nil {
                    bub = { _ in Bubble(progress: 1, content: 1) }
                } else if b.secondary != nil {
                    bub = { t in let g = CGFloat(morphSpring.value(target: 1.0, time: t)); return Bubble(progress: g * g, content: g * g) }
                } else if a.secondary != nil {
                    bub = { t in let g = 1 - CGFloat(morphSpring.value(target: 1.0, time: t)); return Bubble(progress: g, content: g * g) }
                } else {
                    bub = nil
                }
                transition(String(format: "montage%02d", i), a, b, spring: morphSpring, times: times, bubble: bub)
            }
        }

        // 8. Home: the biggest open state, then everything closes back into the notch.
        if want("home") {
            track(); call = nil; setLive([.nowPlaying])
            let compact = snap()
            let home = snap(.expanded(.glance))
            transition("openHome", compact, home, spring: openSpring, times: fps60(0.8))
            hold("homeHold", home, count: 4) { i in track(110 + Double(i)) }
            transition("closeHome", home, compact, spring: closeSpring, times: fps30(0.5))
            silence(); setLive([])
            let idle = snap()
            track(); setLive([.nowPlaying])
            let compact2 = snap()
            silence(); setLive([])
            transition("sleep", compact2, idle, spring: closeSpring, times: fps30(0.5))
        }

        // v2: Flow's brain — real suggestions and questions, the chat, the answer about your day.
        if want("brain") {
            silence(); call = nil; setLive([])
            let idle = snap()
            hold("v2notch", idle, count: 1)
            let suggestions: [(String, BrainSuggestion)] = [
                ("sResume", BrainSuggestion(kind: "resume", symbol: "arrow.uturn.forward", title: "Good morning — continue Mac Flow?",
                                            detail: "You were coding in Xcode · opens Xcode, Terminal, Safari", actionTitle: "Continue",
                                            action: .none, confidence: 0.75)),
                ("sMeeting", BrainSuggestion(kind: "meeting", symbol: "calendar.badge.clock", title: "Design Review in 5 min",
                                             detail: "You’ve been coding on Mac Flow for 52m — a timer to wrap up?", actionTitle: "Wrap-Up Timer",
                                             action: .none, confidence: 0.72)),
                ("sBreak", BrainSuggestion(kind: "break", symbol: "figure.walk", title: "2h of coding — a short break?",
                                           detail: "A five-minute pause keeps the next hour sharp", actionTitle: "5-Min Break",
                                           action: .none, confidence: 0.6)),
                ("sFocus", BrainSuggestion(kind: "focus", symbol: "scope", title: "Protect the next 25 minutes?",
                                           detail: "14 app switches in the last 15 minutes", actionTitle: "Start Focus",
                                           action: .none, confidence: 0.58)),
                ("sError", BrainSuggestion(kind: "error", symbol: "ladybug.fill", title: "Want help with that error?",
                                           detail: "Fatal error: Index out of range", actionTitle: "Ask Claude",
                                           action: .none, confidence: 0.7)),
                ("sRoutine", BrainSuggestion(kind: "routine", symbol: "arrow.triangle.branch", title: "Open Figma too?",
                                             detail: "You open it after Slack 86% of the time", actionTitle: "Open",
                                             action: .none, confidence: 0.8)),
                ("sMusic", BrainSuggestion(kind: "music", symbol: "music.note", title: "ODESZA for coding?",
                                           detail: "Your coding music · also Bonobo, Tycho", actionTitle: "Play",
                                           action: .none, confidence: 0.64)),
                ("sRecap", BrainSuggestion(kind: "day", symbol: "sun.horizon.fill", title: "Want a quick recap of today?",
                                           detail: "6h 12m of work across your apps", actionTitle: "Recap",
                                           action: .none, confidence: 0.55)),
            ]
            for (name, sug) in suggestions {
                let a = snap(.alert, alert: .brainSuggestion(sug))
                transition(name, idle, a, spring: openSpring, times: fps30(0.6))
            }
            let q = BrainQuestion(key: "pref:music.coding", text: "Do you like music while coding?",
                                  detail: "I’ll suggest it at the right moment — or never.",
                                  options: [.init(label: "Yes", value: "yes"), .init(label: "Sometimes", value: "s"), .init(label: "No", value: "no")])
            let qa = snap(.alert, alert: .brainQuestion(q))
            transition("sQuestion", idle, qa, spring: openSpring, times: fps30(0.6))
            // Accepting the wrap-up: the card gives way to a 4-minute timer.
            let meetingCard = snap(.alert, alert: .brainSuggestion(suggestions[1].1))
            FocusTimer.shared.start(minutes: 4, label: "Wrap up"); FocusTimer.shared.debugFreeze(remaining: 240)
            setLive([.timer])
            let wrap = snap()
            transition("sAccept", meetingCard, wrap, spring: closeSpring, times: fps30(0.5))
            hold("sWrapTick", wrap, count: 3) { i in FocusTimer.shared.debugFreeze(remaining: 240 - Double(i)) }
            FocusTimer.shared.stop(); setLive([])
        }

        if want("answer") {
            silence(); setLive([])
            let idle = snap()
            SearchModel.shared.reset(); SearchModel.shared.prepare()
            let question = "What did I get done today?"
            let answer = "You spent 2h 10m coding — mostly on Mac Flow in Xcode and Terminal — plus 40 minutes in Figma and the Design Review. The settings refactor is still open."
            BrainChat.shared.debugSet(question: question, answer: "", phase: .thinking)
            SearchModel.shared.showBrainAnswer()
            let s0 = snap(.search)
            transition("aOpen", idle, s0, spring: morphSpring, times: fps30(0.5), live: true)
            let words = answer.split(separator: " ").map(String.init)
            var steps: [String] = [""]
            for n in stride(from: 2, through: words.count, by: 2) { steps.append(words.prefix(n).joined(separator: " ")) }
            steps.append(answer)
            hold("aStream", s0, count: steps.count, live: true) { i in
                BrainChat.shared.debugSet(question: question, answer: steps[i], phase: i == steps.count - 1 ? .done : (i == 0 ? .thinking : .answering))
                SearchModel.shared.showBrainAnswer()
            }
        }

        if want("montage5") {
            struct M { let live: [ActivityKind]; let mode: IslandMode; let alert: IslandAlert?; let prep: () -> Void }
            let claudeDone = IslandAlert.claudeFinished(id: "a", name: "Refactor the settings window", duration: 734)
            let states: [M] = [
                M(live: [.nowPlaying], mode: .compact, alert: nil) { track() },
                M(live: [], mode: .alert, alert: airpods(1)) { silence() },
                M(live: [.call], mode: .compact, alert: nil) { call = ActivityCenter.Call(app: facetime, since: Date().addingTimeInterval(-754), camera: true) },
                M(live: [.download], mode: .expanded(.activity(.download)), alert: nil) {
                    DownloadsWatcher.shared.debugSet(.init(name: "Xcode_27.xip", progress: 0.62, bytes: 2_100_000_000)) },
                M(live: [], mode: .alert, alert: .charging(76)) {},
                M(live: [.meeting], mode: .compact, alert: nil) {},
                M(live: [.custom], mode: .expanded(.activity(.custom)), alert: nil) { build(0.64) },
                M(live: [], mode: .alert, alert: claudeDone) {},
                M(live: [.timer, .nowPlaying], mode: .compact, alert: nil) { track(); timer(1312) },
                M(live: [.nowPlaying], mode: .alert, alert: .trackChanged) { FocusTimer.shared.stop(); track() },
                M(live: [.nowPlaying], mode: .compact, alert: nil) { track() },
            ]
            for i in 0..<(states.count - 1) {
                let s = states[i], t = states[i + 1]
                s.prep(); t.prep()
                setLive(s.live)
                let a = snap(s.mode, alert: s.alert)
                setLive(t.live)
                let b = snap(t.mode, alert: t.alert)
                let times = (0..<9).map { Double($0) / 15 }
                let bub: ((Double) -> Bubble?)?
                if a.secondary != nil && b.secondary != nil {
                    bub = { _ in Bubble(progress: 1, content: 1) }
                } else if b.secondary != nil {
                    bub = { t in let g = CGFloat(morphSpring.value(target: 1.0, time: t)); return Bubble(progress: g * g, content: g * g) }
                } else if a.secondary != nil {
                    bub = { t in let g = 1 - CGFloat(morphSpring.value(target: 1.0, time: t)); return Bubble(progress: g, content: g * g) }
                } else {
                    bub = nil
                }
                transition(String(format: "m5_%02d", i), a, b, spring: morphSpring, times: times, bubble: bub)
            }
            track(); setLive([.nowPlaying])
            let compact = snap()
            let home = snap(.expanded(.glance))
            transition("home5", compact, home, spring: openSpring, times: fps60(0.8))
        }

        if only?.contains(where: { $0.hasPrefix("v3") }) == true { v3(want) }
        if want("extras") { extras() }

        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
            let name = only == nil ? "manifest.json" : "manifest-\(only!.sorted().joined(separator: "_")).json"
            try? data.write(to: out.appendingPathComponent(name))
        }
        FocusTimer.shared.stop()
        print("film ok → \(outDir)")
    }

    // MARK: Extras: cursors, menu bar symbols, Dock icons, a document icon

    static func extras() {
        let dir = out.appendingPathComponent("extras")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func savePNG(_ img: NSImage, _ px: CGSize, _ name: String) {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px.width), pixelsHigh: Int(px.height), bitsPerSample: 8,
                                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0) else { return }
            rep.size = px
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            NSGraphicsContext.current?.imageInterpolation = .high
            img.draw(in: NSRect(origin: .zero, size: px), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(name).png"))
        }
        var meta: [String: Any] = [:]
        let k: CGFloat = 8
        for (name, c) in [("cursor-arrow", NSCursor.arrow), ("cursor-hand", NSCursor.pointingHand),
                          ("cursor-grab", NSCursor.closedHand)] {
            let s = c.image.size
            savePNG(c.image, CGSize(width: s.width * k, height: s.height * k), name)
            meta[name] = ["size": [s.width, s.height], "hotspot": [c.hotSpot.x, c.hotSpot.y], "scale": k]
        }
        let apps: [(String, String)] = [
            ("finder", "/System/Library/CoreServices/Finder.app"), ("safari", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"),
            ("messages", "/System/Applications/Messages.app"), ("mail", "/System/Applications/Mail.app"),
            ("facetime", "/System/Applications/FaceTime.app"), ("calendar", "/System/Applications/Calendar.app"),
            ("notes", "/System/Applications/Notes.app"), ("music", "/System/Applications/Music.app"),
            ("photos", "/System/Applications/Photos.app"), ("xcode", "/Applications/Xcode.app"),
            ("terminal", "/System/Applications/Utilities/Terminal.app"), ("settings", "/System/Applications/System Settings.app"),
            ("macflow", ProcessInfo.processInfo.environment["FILM_APP"] ?? "/Applications/Mac Flow.app"),
            ("trash", "/System/Library/CoreServices/Dock.app/Contents/Resources/trashempty2.png"),
        ]
        for (name, path) in apps where FileManager.default.fileExists(atPath: path) {
            let img = path.hasSuffix(".png") ? (NSImage(contentsOfFile: path) ?? NSImage()) : NSWorkspace.shared.icon(forFile: path)
            savePNG(img, CGSize(width: 512, height: 512), "dock-\(name)")
        }
        savePNG(NSWorkspace.shared.icon(for: .pdf), CGSize(width: 512, height: 512), "doc-pdf")
        let symbols = ["apple.logo", "wifi", "battery.75percent", "switch.2", "magnifyingglass", "airpodspro",
                       "rectangle.on.rectangle", "speaker.wave.2.fill",
                       "chevron.left.forwardslash.chevron.right", "pencil.line", "paintbrush.pointed.fill", "video.fill",
                       "bubble.left.and.bubble.right.fill", "book.fill", "calendar", "play.rectangle.fill", "music.note",
                       "lock.fill", "cpu", "eye.slash.fill"]
        for s in symbols {
            for (tone, color) in [("black", Color.black), ("white", Color.white)] {
                let v = Image(systemName: s).font(.system(size: 15, weight: .medium)).foregroundStyle(color)
                    .frame(width: 30, height: 22)
                let r = ImageRenderer(content: v)
                r.scale = 8
                r.isOpaque = false
                if let cg = r.cgImage {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                        .write(to: dir.appendingPathComponent("sym-\(s)-\(tone).png"))
                }
            }
        }
        meta["symbolBox"] = [30, 22, 8]
        if let data = try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]) {
            try? data.write(to: dir.appendingPathComponent("extras.json"))
        }
        print("  extras ok")
    }
}
#endif
