#if DEBUG || ATOLL_PROBE
import AppKit
import QuartzCore

/// Debug-only: drives the real island through its transitions and measures every display frame
/// (missed deadlines = visible lag), and captures Atoll's own island window so the composited
/// result can be reviewed frame by frame. Nothing outside Atoll's own window is ever captured.
@MainActor
final class PerfProbe: NSObject {
    private typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var segment = ""
    private var samples: [String: [Double]] = [:]
    private var order: [String] = []
    private let outDir: String
    private var capturing = false
    private var captureIndex = 0

    init(outDir: String) {
        self.outDir = outDir
        super.init()
    }

    func start() {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.run() }
    }

    private func run() {
        guard let controller = IslandManager.shared.primary else { print("probe: no island"); NSApp.terminate(nil); return }
        let model = controller.model
        let view = controller.panel.contentView!
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l

        NowPlayingModel.shared.debugInject(title: "Midnight City", artist: "M83", duration: 243, elapsed: 97, artwork: ProcessInfo.processInfo.environment["ATOLL_ART"].flatMap { NSImage(contentsOfFile: $0) })
        func timed(_ label: String, _ f: () -> Void) {
            let t = CACurrentMediaTime()
            f()
            controller.panel.contentView?.layoutSubtreeIfNeeded()
            print(String(format: "  %@ main %.1f ms", label, (CACurrentMediaTime() - t) * 1000))
        }
        let claudeLive = model.live.contains(.claude)
        print("probe: live = \(model.live.map(\.rawValue)), claude sessions = \(ClaudeSessions.shared.sessions.count)")
        let flow: [(String, Double, () -> Void)] = claudeLive ? [
            // The real hover path: the compact island swells, then opens Home after the hover delay.
            ("hover-swell", 0.18, { timed("swell") { model.setHovering(true) } }),
            ("hover-home", 1.0, { timed("home") { model.expand(.glance, sticky: true) } }),
            ("tab-claude", 1.0, { timed("tab-claude") { model.select(.activity(.claude)) } }),
            ("tab-home", 1.0, { timed("tab-home") { model.select(.glance) } }),
            ("tab-claude-2", 1.0, { timed("tab-claude-2") { model.select(.activity(.claude)) } }),
            ("tab-home-2", 1.0, { timed("tab-home-2") { model.select(.glance) } }),
            ("probe-state", 0.01, { print("  state after tabs: \(model.mode)") }),
            ("close-h", 1.0, { timed("close") { model.collapse() } }),
            ("hover-swell-2", 0.18, { model.setHovering(true) }),
            ("hover-home-2", 1.0, { timed("home-2") { model.expand(.glance, sticky: true) } }),
            ("close-h2", 1.0, { model.collapse() }),
        ] : []
        // ATOLL_LOOP=1: the everyday moves, eight times each, for medians instead of one noisy run.
        if ProcessInfo.processInfo.environment["ATOLL_LOOP"] != nil {
            var loop: [(String, Double, () -> Void)] = []
            let only = ProcessInfo.processInfo.environment["ATOLL_LOOP"] ?? ""
            for i in 0..<(only == "search" ? 14 : 8) where only == "search" {
                loop += [("open-search#\(i)", 0.9, { model.openSearch() }), ("close-search#\(i)", 0.9, { model.collapse() })]
            }
            for i in 0..<8 where only != "search" {
                loop += [
                    ("open-home#\(i)", 0.9, { model.expand(.glance, sticky: true) }),
                    ("to-controls#\(i)", 0.9, { model.select(.controls) }),
                    ("to-home#\(i)", 0.9, { model.select(.glance) }),
                    ("close-home#\(i)", 0.9, { model.collapse() }),
                    ("open-music#\(i)", 0.9, { model.expand(.activity(.nowPlaying), sticky: true) }),
                    ("close-music#\(i)", 0.9, { model.collapse() }),
                    ("open-search#\(i)", 0.9, { model.openSearch() }),
                    ("close-search#\(i)", 0.9, { model.collapse() }),
                ]
            }
            runSteps(loop, controller: controller)
            return
        }
        let steps: [(String, Double, () -> Void)] = flow + [
            ("home-music-open", 1.0, { model.expand(.glance, sticky: true) }),
            ("home-music-steady", 2.0, { PerfProbe.cpuMark = PerfProbe.cpuSeconds() }),
            ("controls", 1.2, {
                // The steady window only (it used to divide by 2 s across every step up to the close).
                print(String(format: "  home open with music: CPU %.1f%% of one core", (PerfProbe.cpuSeconds() - PerfProbe.cpuMark) / 2.0 * 100))
                timed("controls") { model.select(.controls) }
            }),
            ("controls-home", 1.0, { timed("controls-home") { model.select(.glance) } }),
            ("brain", 1.2, { timed("brain") { model.select(.brain) } }),
            ("brain-home", 1.0, { timed("brain-home") { model.select(.glance) } }),
            ("plan", 1.2, { timed("plan") { model.select(.plan) } }),
            ("plan-home", 1.0, { timed("plan-home") { model.select(.glance) } }),
            ("rewind", 1.2, { timed("rewind") { model.select(.rewind) } }),
            ("day", 1.6, { timed("day") { model.select(.day) } }),
            ("day-home", 1.0, { timed("day-home") { model.select(.glance) } }),
            ("home-music-close", 1.0, { model.collapse() }),
            ("idle", 1.0, {}),
            ("open-music", 1.0, { model.expand(.activity(.nowPlaying), sticky: true) }),
            ("close", 1.0, { model.collapse() }),
            ("open-home", 1.0, { model.expand(.glance, sticky: true) }),
            ("switch-to-music", 1.0, { model.expand(.activity(.nowPlaying), sticky: true) }),
            ("close-2", 1.0, { model.collapse() }),
            ("open-plan", 1.2, { model.openPlan() }),
            ("close-plan", 1.0, { model.collapse() }),
            ("open-search", 1.2, { model.openSearch() }),
            ("close-search", 1.0, { model.collapse() }),
            ("open-home-2", 1.0, { model.expand(.glance, sticky: true) }),
            ("close-3", 1.0, { model.collapse() }),
            ("open-search-2", 1.2, {
                var t = CACurrentMediaTime()
                SearchModel.shared.prepare()
                print(String(format: "  prepare %.1f ms", (CACurrentMediaTime() - t) * 1000))
                t = CACurrentMediaTime()
                controller.panel.makeKey()
                print(String(format: "  makeKey %.1f ms", (CACurrentMediaTime() - t) * 1000))
                t = CACurrentMediaTime()
                model.openSearch()
                print(String(format: "  openSearch %.1f ms", (CACurrentMediaTime() - t) * 1000))
                t = CACurrentMediaTime()
                controller.panel.contentView?.layoutSubtreeIfNeeded()
                controller.panel.displayIfNeeded()
                print(String(format: "  first layout+display %.1f ms", (CACurrentMediaTime() - t) * 1000))
            }),
            ("close-search-2", 1.0, { model.collapse() }),
            // Search with files showing (thumbnails, icons, preview), then straight to closed.
            ("search-files", 1.6, { model.openSearch(); SearchModel.shared.query = "design" }),
            ("close-files", 1.2, { timed("close-files") { model.collapse() } }),
        ]
        runSteps(steps, controller: controller)
    }

    private func runSteps(_ steps: [(String, Double, () -> Void)], controller: IslandController) {
        var t = 0.0
        for (name, duration, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                self.segment = name
                self.order.append(name)
                // Frames for review: the compact island at rest, an open and a close (Core Animation layers inside
                // the island must grow, shrink and clip with it), and Controls.
                let captures: [String: (String, Int)] = ["home-music-steady": ("steady", 4), "idle": ("idle", 2),
                                                         "hover-home": ("open", 14), "close-h": ("close", 14),
                                                         "controls": ("f", 36)]
                if let (prefix, frames) = captures[name], ProcessInfo.processInfo.environment["ATOLL_NOCAPTURE"] == nil {
                    let f = controller.panel.frame
                    let top = NSScreen.screens.first?.frame.maxY ?? f.maxY
                    self.startCapture(window: controller.panel.windowNumber, frames: frames, prefix: prefix,
                                      rect: CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height))
                }
                action()
            }
            t += duration
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.2) { self.finish() }
    }

    static var cpuMark = 0.0
    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1_000_000
    }

    /// Slow frames, with when they landed in their step (ms after it began) — to tell a hitch inside a spring from one after it.
    private var slow: [String: [(at: Int, ms: Double)]] = [:]
    private var segmentStart: CFTimeInterval = 0
    private var lastSegment = ""

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if segment != lastSegment { lastSegment = segment; segmentStart = now }
        if last > 0, !segment.isEmpty {
            let ms = (now - last) * 1000
            samples[segment, default: []].append(ms)
            if ms > 25 { slow[segment, default: []].append((Int((now - segmentStart) * 1000), ms)) }
        }
        last = now
    }

    private func finish() {
        link?.invalidate()
        let nominal = (link?.duration ?? 1.0 / 120.0) * 1000
        print(String(format: "display frame %.1f ms (%.0f Hz)", nominal, 1000 / nominal))
        // Looped runs: per move, the median first frame and dropped frames.
        var groups: [String: [(first: Double, missed: Int)]] = [:]
        var groupOrder: [String] = []
        for name in order where name.contains("#") {
            let base = String(name.split(separator: "#")[0])
            let s = samples[name] ?? []
            let missed = s.reduce(0) { $0 + max(0, Int(($1 / nominal).rounded()) - 1) }
            if groups[base] == nil { groupOrder.append(base) }
            groups[base, default: []].append((s.first ?? 0, missed))
        }
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        for base in groupOrder {
            let g = groups[base]!
            print(String(format: "LOOP %-14@ first frame median %5.1f ms · worst %5.1f ms · dropped median %d · total %d", base as NSString,
                         median(g.map(\.first)), g.map(\.first).max() ?? 0, Int(median(g.map { Double($0.missed) })), g.reduce(0) { $0 + $1.missed }))
        }
        for name in order {
            let s = samples[name] ?? []
            let dropped = s.reduce(0) { $0 + max(0, Int(($1 / nominal).rounded()) - 1) }
            let worst = s.max() ?? 0
            let when = (slow[name] ?? []).map { String(format: "%d:%.0f", $0.at, $0.ms) }.joined(separator: " ")
            print(String(format: "%-16@ frames %3d  missed %3d  worst %5.1f ms", name as NSString, s.count, dropped, worst) + (when.isEmpty ? "" : "   slow at " + when))
        }
        NowPlayingModel.shared.debugInject(title: "", artist: "", duration: 0, elapsed: 0, artwork: nil, playing: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }

    /// Captures only Atoll's island window, off the main thread, ~60 times a second.
    private func startCapture(window: Int, frames: Int, prefix: String = "f", rect: CGRect = .null) {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImage") else { return }
        let fn = unsafeBitCast(sym, to: CaptureFn.self)
        let dir = outDir
        DispatchQueue.global(qos: .userInitiated).async {
            let start = CACurrentMediaTime()
            for i in 0..<frames {
                let target = start + Double(i) / 60
                let wait = target - CACurrentMediaTime()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                // kCGWindowListOptionIncludingWindow = 8 (this window only), nominal resolution = 16.
                guard let img = fn(rect, 8, UInt32(window), 16)?.takeRetainedValue() else { continue }
                let ms = Int((CACurrentMediaTime() - start) * 1000)
                let rep = NSBitmapImageRep(cgImage: img)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%@%02d-%04dms.png", prefix, i, ms)))
            }
        }
    }
}
#endif
