#if DEBUG
import AppKit

/// Debug-only: runs the real app, then captures *only Atoll's own windows*, one by one, and composes
/// them on a neutral canvas at their real positions. Nothing else on screen is ever read.
@MainActor
enum LiveCapture {
    private typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Checks the Dock companion: opened from a menu it must stay up; the handle must draw.
    static func dockCheck(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let dock = DockBarController.shared
        let steps: [(TimeInterval, () -> Void)] = [
            (3.0, { dock.show(manual: true) }),
            (5.5, {
                print("bar shown after 2.5 s: \(dock.isShown), on screen: \(dock.debugOnScreen)")
                compose("95-dock-bar", [dock.debugWindowNumber], outDir)
                dock.hide()
            }),
            (6.0, { DockDropController.shared.debugShowTray() }),
            (6.8, { compose("97-dock-tray", [DockDropController.shared.debugWindowNumber], outDir); DockDropController.shared.debugHideTray() }),
            (7.0, { dock.debugShowHandle(hot: true) }),
            (7.8, { compose("96-dock-handle", [dock.debugHandleWindowNumber], outDir) }),
            (8.2, { NSApp.terminate(nil) }),
        ]
        for (t, step) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { step() } }
    }

    /// `--page-check`: the model side of Summarize and Save to Learn, on a long real document (the README).
    static func pageCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("README.md")
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? String(repeating: "A page about something. ", count: 600)
            print("model available: \(Mind.shared.isAvailable) \(Mind.shared.unavailableReason) · text \(text.count) chars")
            let start = Date()
            Task { @MainActor in
                var last = ""
                do {
                    for try await t in Mind.shared.onPage("Summarize this page in three short bullets, then one line on why it matters.", title: "Mac Flow README", text: text) { last = t }
                } catch { last = "error: \(error.localizedDescription)" }
                print(String(format: "summary (%.1fs):\n%@", Date().timeIntervalSince(start), last))
                let cards = await LearnStore.debugWrite(text, title: "Mac Flow README")
                print("cards: \(cards.count)\n" + cards.map { "Q: \($0.0)\nA: \($0.1)" }.joined(separator: "\n"))
                NSApp.terminate(nil)
            }
        }
    }

    /// Prints what the Claude tracker sees on this Mac (states only — no names).
    static func claudeCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            let list = ClaudeSessions.shared.sessions
            print("claude sessions: \(list.count) — " + list.map { "\($0.state)\($0.viaDesktop ? "·desktop" : "")" }.joined(separator: ", "))
            print("featured: \(ClaudeSessions.shared.featured.map { "\($0.state)" } ?? "none"), live: \(ActivityCenter.shared.live.map(\.rawValue))")
            print("ask: installed \(ClaudeAsk.shared.isInstalled), signed in \(ClaudeAsk.shared.signedIn.map(String.init(describing:)) ?? "unknown")")
            NSApp.terminate(nil)
        }
    }

    /// Runs the Brain briefly on this Mac, then asks the on-device model a question from the digest.
    static func brainCheck() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            let ctx = WorkContext.shared
            print("mode: \(ctx.mode) · app: \(ctx.appName) · project: \(ctx.project ?? "none") · level: \(ctx.level.title)")
            print("model available: \(Mind.shared.isAvailable)")
            let digest = BrainEngine.shared.digest()
            print("digest (\(digest.count) chars):\n\(digest.prefix(500))")
            let start = Date()
            Task { @MainActor in
                var last = ""
                do {
                    for try await t in Mind.shared.answer("What am I doing right now, in one sentence?", context: digest) { last = t }
                } catch { last = "error: \(error.localizedDescription)" }
                print(String(format: "answer (%.1fs): %@", Date().timeIntervalSince(start), last))
                NSApp.terminate(nil)
            }
        }
    }

    static func schedule(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let steps: [(TimeInterval, () -> Void)] = [
            // Widgets live on the desktop layer, so capturing them never puts anything in front of you.
            (4.0, { compose("90-live-widgets", WidgetManager.shared.debugWindowNumbers, outDir) }),
            (4.5, { NSApp.terminate(nil) }),
        ]
        for (t, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { step() }
        }
    }

    /// `--standby-check <dir>`: StandBy on screen for a few seconds — clock, Now Playing with demo lyrics, analog —
    /// each captured from Mac Flow's own window (Liquid Glass only draws on screen).
    static func standByCheck(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let sb = StandByController.shared
        let prefs = Prefs.shared
        let saved = (prefs.standByWallpaper, prefs.standByClockStyle)
        let wallpaper = ProcessInfo.processInfo.environment["ATOLL_WALLPAPER"] ?? "dunes"
        func snap(_ name: String) {
            guard let n = sb.debugWindowNumber, let fn = capture(),
                  let image = fn(.null, 8, UInt32(n), 8)?.takeRetainedValue() else { print("no capture for \(name)"); return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png"))
            print("captured \(name) \(image.width)x\(image.height)")
        }
        let steps: [(TimeInterval, () -> Void)] = [
            (2.0, {
                prefs.standByWallpaper = wallpaper
                prefs.standByClockStyle = StandByClockStyle.glass.rawValue
                sb.debugShow(page: .clock)
            }),
            (5.5, {
                snap("s1-clock-glass")
                let np = NowPlayingModel.shared, l = LyricsModel.shared
                print("lyrics for the song playing (\(np.source?.name ?? "none"), \(Int(np.duration)) s): \(l.status) — \(l.lyrics?.lines.count ?? 0) lines, synced \(l.lyrics?.synced ?? false), from \(l.lyrics?.source ?? "-")")
            }),
            (5.7, {
                LyricsModel.shared.follow(false)
                NowPlayingModel.shared.debugInjectApp(nil)
                NowPlayingModel.shared.debugInject(title: "Midnight City", artist: "M83", duration: 243, elapsed: 74,
                                                   artwork: SurfaceHarness.demoCover())
                LyricsModel.shared.debugSet(SurfaceHarness.demoLyrics)
                sb.debugPage(.nowPlaying)
                sb.debugNight(true)
            }),
            (9.0, { snap("s2-nowplaying-lyrics") }),
            (9.2, { prefs.standByClockStyle = StandByClockStyle.analog.rawValue; sb.debugPage(.clock) }),
            (11.5, { snap("s3-clock-analog") }),
            (11.7, { sb.debugPage(.widgets) }),
            (13.5, { snap("s4-widgets") }),
            (13.7, {
                sb.exit()
                prefs.standByWallpaper = saved.0
                prefs.standByClockStyle = saved.1
            }),
            (14.4, { NSApp.terminate(nil) }),
        ]
        for (t, step) in steps { DispatchQueue.main.asyncAfter(deadline: .now() + t) { step() } }
    }

    private static func compose(_ name: String, _ windows: [Int], _ outDir: String) {
        guard let fn = capture(), let screen = NSScreen.screens.first else { return }
        let size = screen.frame.size
        let canvas = NSImage(size: size)
        canvas.lockFocus()
        NSGradient(colors: [NSColor(red: 0.26, green: 0.42, blue: 0.62, alpha: 1), NSColor(red: 0.86, green: 0.6, blue: 0.5, alpha: 1)])?
            .draw(in: NSRect(origin: .zero, size: size), angle: -35)
        for number in windows {
            guard let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(number)) as? [[String: Any]])?.first,
                  (info[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let w = b["Width"], let h = b["Height"], w > 0, h > 0 else { continue }
            // kCGWindowListOptionIncludingWindow = 8 — just this window. kCGWindowImageBestResolution = 8.
            guard let image = fn(.null, 8, UInt32(number), 8)?.takeRetainedValue() else { print("no image for window \(number)"); continue }
            print("window \(number) at \(x),\(y) \(w)x\(h) image \(image.width)x\(image.height)")
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(name)-raw.png"))
            NSImage(cgImage: image, size: NSSize(width: w, height: h))
                .draw(in: NSRect(x: x, y: size.height - y - h, width: w, height: h))
        }
        canvas.unlockFocus()
        guard let tiff = canvas.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outDir).appendingPathComponent("\(name).png"))
        print("captured \(name) (\(windows.count) windows)")
    }

    private static func capture() -> CaptureFn? {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImage") else { return nil }
        return unsafeBitCast(sym, to: CaptureFn.self)
    }
}
#endif
