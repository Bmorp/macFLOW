#if DEBUG || ATOLL_PROBE
import AppKit
import QuartzCore
import os

/// Debug-only: drives the real island through its transitions and measures every display frame
/// (missed deadlines = visible lag), and captures Atoll's own island window so the composited
/// result can be reviewed frame by frame. Nothing outside Atoll's own window is ever captured.
///
/// Per step it records display frames (and a 120 Hz histogram of them), main-thread busy time (from run-loop
/// wake to sleep), island-root body evaluations, and an Instruments signpost. Environment:
/// - `ATOLL_LOOP=1` the everyday moves eight times each, for medians; `ATOLL_LOOP=search` Search only.
/// - `ATOLL_LOOP=stall` with `ATOLL_STALL=<ms>`: opens and closes Home with the main thread blocked for that long
///   80 ms into each move, capturing the window off the main thread to count frames where the shape stood still.
/// - `ATOLL_NOCAPTURE=1` no window captures.
@MainActor
final class PerfProbe: NSObject {
    private typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var segment = ""
    private var order: [String] = []
    private let outDir: String
    private var signpost: OSSignpostIntervalState?

    /// Everything measured for one step.
    private struct Step {
        var frames: [Double] = []
        /// Island-root body evaluations: in the step's first frame, and after it (the animation's frames).
        var bodiesFirst = 0
        var bodiesAfter = 0
        /// Main-thread busy time during the step, and the busy time of the action itself (action + layout).
        var busy: Double = 0
        var action: Double = 0
    }
    private var steps: [String: Step] = [:]

    init(outDir: String) {
        self.outDir = outDir
        super.init()
    }

    func start() {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.run() }
    }

    private static var env: [String: String] { ProcessInfo.processInfo.environment }

    private func run() {
        guard let controller = IslandManager.shared.primary else { print("probe: no island"); NSApp.terminate(nil); return }
        let model = controller.model
        let view = controller.panel.contentView!
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        watchRunLoop()

        NowPlayingModel.shared.debugInject(title: "Midnight City", artist: "M83", duration: 243, elapsed: 97, artwork: Self.env["ATOLL_ART"].flatMap { NSImage(contentsOfFile: $0) })
        func timed(_ label: String, _ f: () -> Void) {
            let t = CACurrentMediaTime()
            f()
            controller.panel.contentView?.layoutSubtreeIfNeeded()
            print(String(format: "  %@ main %.1f ms", label, (CACurrentMediaTime() - t) * 1000))
        }
        let claudeLive = model.live.contains(.claude)
        print("probe: live = \(model.live.map(\.rawValue)), claude sessions = \(ClaudeSessions.shared.sessions.count), engine = \(controller.usesEngine ? "on" : "legacy")")
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
        let idle: [(String, Double, () -> Void)] = [
            ("settle", 2.0, { model.collapse() }),
            ("idle-cpu", 4.0, { PerfProbe.cpuMark = PerfProbe.cpuSeconds() }),
            ("idle-report", 0.05, {
                print(String(format: "idle (closed, nothing moving): CPU %.2f%% of one core", (PerfProbe.cpuSeconds() - PerfProbe.cpuMark) / 4.0 * 100))
                print("engine: \(IslandTrace.syncs) syncs, \(IslandTrace.bakes) bakes in the whole run")
            }),
        ]
        // ATOLL_LOOP=1: the everyday moves, eight times each, for medians instead of one noisy run.
        if let only = Self.env["ATOLL_LOOP"] {
            var loop: [(String, Double, () -> Void)] = []
            if only == "stall" {
                let ms = Double(Self.env["ATOLL_STALL"] ?? "50") ?? 50
                for i in 0..<8 {
                    loop += [("stall-open#\(i)", 0.9, { self.stallTest(controller, ms: ms, name: "open\(i)") { model.expand(.glance, sticky: true) } }),
                             ("stall-close#\(i)", 0.9, { self.stallTest(controller, ms: ms, name: "close\(i)") { model.collapse() } })]
                }
                // No idle window here: the captures' analysis is still finishing in the background.
                runSteps(loop, controller: controller)
                return
            }
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
            runSteps(loop + idle, controller: controller)
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
        ] + idle
        runSteps(steps, controller: controller)
    }

    private func runSteps(_ steps: [(String, Double, () -> Void)], controller: IslandController) {
        var t = 0.0
        for (name, duration, action) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                self.begin(name)
                // Frames for review: the compact island at rest, an open and a close (Core Animation layers inside
                // the island must grow, shrink and clip with it), and Controls.
                let captures: [String: (String, Int)] = ["home-music-steady": ("steady", 4), "idle": ("idle", 2),
                                                         "hover-home": ("open", 14), "close-h": ("close", 14),
                                                         "controls": ("f", 36)]
                if let (prefix, frames) = captures[name], Self.env["ATOLL_NOCAPTURE"] == nil {
                    self.startCapture(controller: controller, frames: frames, prefix: prefix)
                }
                let t0 = CACurrentMediaTime()
                action()
                controller.panel.contentView?.layoutSubtreeIfNeeded()
                self.steps[name, default: Step()].action = (CACurrentMediaTime() - t0) * 1000
            }
            t += duration
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.2) { self.finish() }
    }

    private func begin(_ name: String) {
        if let s = signpost { IslandTrace.signposter.endInterval("probe step", s) }
        signpost = IslandTrace.signposter.beginInterval("probe step", id: IslandTrace.signposter.makeSignpostID(), "\(name, privacy: .public)")
        segment = name
        order.append(name)
        bodyMark = IslandTrace.rootBodies
        firstFrameSeen = false
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
    private var bodyMark = 0
    private var firstFrameSeen = false

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if segment != lastSegment { lastSegment = segment; segmentStart = now }
        if last > 0, !segment.isEmpty {
            let ms = (now - last) * 1000
            steps[segment, default: Step()].frames.append(ms)
            if ms > 25 { slow[segment, default: []].append((Int((now - segmentStart) * 1000), ms)) }
            let bodies = IslandTrace.rootBodies - bodyMark
            bodyMark = IslandTrace.rootBodies
            if firstFrameSeen { steps[segment, default: Step()].bodiesAfter += bodies } else { steps[segment, default: Step()].bodiesFirst += bodies }
            firstFrameSeen = true
        }
        last = now
    }

    // MARK: Main-thread busy time

    private var observers: [CFRunLoopObserver] = []
    private var wokeAt: CFTimeInterval = 0

    /// Busy = from the run loop waking (first observer to run) to it going back to sleep (last observer to run, after
    /// Core Animation's commit) — so layout, SwiftUI updates and the commit all count.
    private func watchRunLoop() {
        let wake = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.afterWaiting.rawValue, true, CFIndex.min) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.wokeAt = CACurrentMediaTime() }
        }
        let sleep = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, CFRunLoopActivity.beforeWaiting.rawValue, true, CFIndex.max) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.wokeAt > 0, !self.segment.isEmpty else { return }
                self.steps[self.segment, default: Step()].busy += (CACurrentMediaTime() - self.wokeAt) * 1000
                self.wokeAt = 0
            }
        }
        for o in [wake, sleep] {
            if let o { CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes); observers.append(o) }
        }
    }

    // MARK: Report

    private func finish() {
        if let s = signpost { IslandTrace.signposter.endInterval("probe step", s) }
        link?.invalidate()
        observers.forEach { CFRunLoopObserverInvalidate($0) }
        let nominal = (link?.duration ?? 1.0 / 120.0) * 1000
        print(String(format: "display frame %.1f ms (%.0f Hz)", nominal, 1000 / nominal))
        func dropped(_ s: [Double]) -> Int { s.reduce(0) { $0 + max(0, Int(($1 / nominal).rounded()) - 1) } }
        // Looped runs: per move, the median first frame, dropped frames (all, and after the first frame — the first
        // one carries the move's own commit, which delays the start but doesn't hitch it), bodies and main-thread time.
        struct Rep { var first: Double; var missed: Int; var missedAfter: Int; var bodies: Int; var bodiesAfter: Int; var action: Double; var busy: Double; var frames: [Double] }
        var groups: [String: [Rep]] = [:]
        var groupOrder: [String] = []
        for name in order where name.contains("#") {
            let base = String(name.split(separator: "#")[0])
            let st = steps[name] ?? Step()
            let s = st.frames
            if groups[base] == nil { groupOrder.append(base) }
            groups[base, default: []].append(Rep(first: s.first ?? 0, missed: dropped(s), missedAfter: dropped(Array(s.dropFirst())),
                                                 bodies: st.bodiesFirst + st.bodiesAfter, bodiesAfter: st.bodiesAfter,
                                                 action: st.action, busy: st.busy, frames: s))
        }
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        for base in groupOrder {
            let g = groups[base]!
            print(String(format: "LOOP %-14@ first frame median %5.1f ms · worst %5.1f ms · dropped median %d · total %d · after first: median %d total %d",
                         base as NSString, median(g.map(\.first)), g.map(\.first).max() ?? 0, Int(median(g.map { Double($0.missed) })),
                         g.reduce(0) { $0 + $1.missed }, Int(median(g.map { Double($0.missedAfter) })), g.reduce(0) { $0 + $1.missedAfter }))
            print(String(format: "     %-14@ main: action median %.1f ms · busy over the move median %.1f ms · root bodies median %d (in frames after the first: %d total)",
                         "" as NSString, median(g.map(\.action)), median(g.map(\.busy)), Int(median(g.map { Double($0.bodies) })),
                         g.reduce(0) { $0 + $1.bodiesAfter }))
            print("     " + "".padding(toLength: 14, withPad: " ", startingAt: 0) + " 120 Hz histogram " + Self.histogram(g.flatMap(\.frames)))
        }
        for name in order {
            let st = steps[name] ?? Step()
            let s = st.frames
            let worst = s.max() ?? 0
            let when = (slow[name] ?? []).map { String(format: "%d:%.0f", $0.at, $0.ms) }.joined(separator: " ")
            print(String(format: "%-16@ frames %3d  missed %3d  worst %5.1f ms  main %5.1f ms  bodies %d+%d", name as NSString, s.count, dropped(s), worst,
                         st.busy, st.bodiesFirst, st.bodiesAfter) + (when.isEmpty ? "" : "   slow at " + when))
        }
        if !stallReports.isEmpty { reportStalls() }
        NowPlayingModel.shared.debugInject(title: "", artist: "", duration: 0, elapsed: 0, artwork: nil, playing: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
    }

    /// Frame intervals in 120 Hz frames: how many were one frame (8.3 ms), two (16.7), three, four, or longer.
    private static func histogram(_ frames: [Double]) -> String {
        var bins = [0, 0, 0, 0, 0]
        for ms in frames { bins[min(4, max(0, Int((ms / (1000.0 / 120)).rounded()) - 1))] += 1 }
        return "[8.3 ms: \(bins[0]) · 16.7: \(bins[1]) · 25: \(bins[2]) · 33: \(bins[3]) · longer: \(bins[4])]"
    }

    // MARK: Stall test

    /// Per stalled move: the island's height in each captured frame, with the capture time.
    private var stallReports: [(name: String, start: Double, stall: (Double, Double), samples: [(ms: Double, height: Int)])] = []

    /// Runs `action`, blocks the main thread for `ms` 80 ms later, and meanwhile captures the island window off the
    /// main thread to see whether the shape kept moving.
    private func stallTest(_ controller: IslandController, ms: Double, name: String, _ action: () -> Void) {
        let start = CACurrentMediaTime()
        let index = stallReports.count
        stallReports.append((name, start, (80, 80 + ms), []))
        capture(controller: controller, frames: 30) { [weak self] shots in
            // Measured here, off the main thread, so the analysis never shows up as a hitch in the next move.
            let samples = shots.map { (ms: ($0.0 - start) * 1000, height: Self.islandHeight($0.1)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.stallReports[index].samples = samples }
            }
        }
        action()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { usleep(useconds_t(ms * 1000)) }
    }

    /// Opaque rows down the middle column: how tall the island is, in pixels.
    nonisolated private static func islandHeight(_ img: CGImage) -> Int {
        let w = img.width, h = img.height
        guard let ctx = CGContext(data: nil, width: 1, height: h, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        // Draw just the centre column (shifted so it lands in the 1-px-wide context).
        ctx.draw(img, in: CGRect(x: -CGFloat(w / 2), y: 0, width: CGFloat(w), height: CGFloat(h)))
        guard let data = ctx.data else { return 0 }
        let p = data.bindMemory(to: UInt8.self, capacity: h * 4)
        var rows = 0
        // Bitmap memory runs top-down; the island hangs from the top edge.
        for y in 0..<h {
            if p[y * 4 + 3] > 128 { rows += 1 } else { break }
        }
        return rows
    }

    private func reportStalls() {
        print("STALL (main thread blocked 80–\(Int(stallReports[0].stall.1)) ms into each move; shape frames captured off the main thread)")
        var totalStuck = 0
        for r in stallReports {
            // A frame "stood still" if the height didn't change from the last capture while the shape was still
            // travelling (more than 2 px from where it ends).
            guard let final = r.samples.last?.height else { continue }
            var stuck = 0
            var during = 0
            for (a, b) in zip(r.samples, r.samples.dropFirst()) where abs(b.height - final) > 2 {
                if b.ms >= r.stall.0 && b.ms <= r.stall.1 + 17 { during += 1; if a.height == b.height { stuck += 1 } }
            }
            totalStuck += stuck
            let trace = r.samples.prefix(16).map { String(format: "%.0f:%d", $0.ms, $0.height) }.joined(separator: " ")
            print(String(format: "  %@ frames in the stall %d · stood still %d   %@", r.name as NSString, during, stuck, trace))
        }
        print("STALL total frames that stood still while the shape was moving: \(totalStuck)")
    }

    // MARK: Capture

    /// Captures only Atoll's island window, off the main thread, ~60 times a second.
    private func startCapture(controller: IslandController, frames: Int, prefix: String = "f") {
        let dir = outDir
        capture(controller: controller, frames: frames) { shots in
            let start = shots.first?.0 ?? 0
            for (i, shot) in shots.enumerated() {
                let ms = Int((shot.0 - start) * 1000)
                try? NSBitmapImageRep(cgImage: shot.1).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%@%02d-%04dms.png", prefix, i, ms)))
            }
        }
    }

    private func capture(controller: IslandController, frames: Int, done: @escaping @Sendable ([(Double, CGImage)]) -> Void) {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImage") else { return }
        let fn = unsafeBitCast(sym, to: CaptureFn.self)
        let f = controller.panel.frame
        let top = NSScreen.screens.first?.frame.maxY ?? f.maxY
        let rect = CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height)
        let window = UInt32(controller.panel.windowNumber)
        DispatchQueue.global(qos: .userInteractive).async {
            let start = CACurrentMediaTime()
            var shots: [(Double, CGImage)] = []
            for i in 0..<frames {
                let wait = start + Double(i) / 60 - CACurrentMediaTime()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                // kCGWindowListOptionIncludingWindow = 8 (this window only), nominal resolution = 16.
                guard let img = fn(rect, 8, window, 16)?.takeRetainedValue() else { continue }
                shots.append((CACurrentMediaTime(), img))
            }
            // Encode after capturing, so encoding never delays a frame.
            done(shots)
        }
    }
}
#endif
