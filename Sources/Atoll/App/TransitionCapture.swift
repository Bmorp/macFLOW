#if DEBUG || ATOLL_PROBE
import AppKit
import QuartzCore

/// Debug-only: drives the real island (live window, real springs, real Core Animation layers) through every
/// open, close, switch, alert and interrupted transition, and captures Atoll's own island window ~60 times a
/// second during each one — so overlaps, clipping and stray content show up frame by frame.
/// Nothing outside Atoll's own window is ever captured.
///
///     swift build -c release -Xswiftc -DATOLL_PROBE && .build/release/Atoll --transitions /tmp/atoll-transitions
@MainActor
final class TransitionCapture {
    private typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    private struct Scenario {
        let name: String
        /// Puts the island in the starting state (no animation).
        let setup: (IslandModel) -> Void
        /// Timed steps after capture starts: (seconds, action).
        let steps: [(Double, (IslandModel) -> Void)]
        var duration: Double = 0.55
    }

    private let outDir: String
    init(outDir: String) { self.outDir = outDir }

    func start() {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.run() }
    }

    private func run() {
        guard let controller = IslandManager.shared.primary else { print("transitions: no island"); NSApp.terminate(nil); return }
        NowPlayingModel.shared.debugInject(title: "Midnight City — a title long enough to scroll", artist: "M83",
                                           duration: 243, elapsed: 97, artwork: nil)
        // Two live activities, so the bubble (the minimal presentation) is on screen through every transition.
        let startedTimer = !FocusTimer.shared.isActive
        if startedTimer { FocusTimer.shared.start(minutes: 25, label: "Focus") }
        let compact: (IslandModel) -> Void = { $0.collapse() }
        let home: (IslandModel) -> Void = { $0.expand(.glance, sticky: true) }
        let claudeLive = controller.model.live.contains(.claude)
        let page: IslandFocus = claudeLive ? .activity(.claude) : .activity(.nowPlaying)

        var scenarios: [Scenario] = [
            Scenario(name: "01-hover", setup: compact, steps: [(0, { $0.setHovering(true) }), (0.4, { $0.setHovering(false) })], duration: 0.8),
            Scenario(name: "02-open-home", setup: compact, steps: [(0, home)]),
            Scenario(name: "03-close-home", setup: home, steps: [(0, { $0.collapse() })]),
            Scenario(name: "04-open-page", setup: compact, steps: [(0, { $0.expand(page, sticky: true) })]),
            Scenario(name: "05-close-page", setup: { $0.expand(page, sticky: true) }, steps: [(0, { $0.collapse() })]),
            Scenario(name: "06-tab-home-page", setup: home, steps: [(0, { $0.select(page) })]),
            Scenario(name: "07-tab-page-home", setup: { $0.expand(page, sticky: true) }, steps: [(0, { $0.select(.glance) })]),
            Scenario(name: "08-tab-home-controls", setup: home, steps: [(0, { $0.select(.controls) })]),
            Scenario(name: "09-tab-controls-home", setup: { $0.expand(.glance, sticky: true); $0.select(.controls) },
                     steps: [(0, { $0.select(.glance) })]),
            Scenario(name: "10-close-controls", setup: { $0.expand(.glance, sticky: true); $0.select(.controls) },
                     steps: [(0, { $0.collapse() })]),
            Scenario(name: "11-open-music", setup: compact, steps: [(0, { $0.expand(.activity(.nowPlaying), sticky: true) })]),
            Scenario(name: "12-close-music", setup: { $0.expand(.activity(.nowPlaying), sticky: true) }, steps: [(0, { $0.collapse() })]),
            Scenario(name: "13-open-search", setup: compact, steps: [(0, { $0.openSearch() })]),
            Scenario(name: "14-close-search", setup: { $0.openSearch() }, steps: [(0, { $0.collapse() })]),
            Scenario(name: "15-alert-volume", setup: compact,
                     steps: [(0, { $0.showAlert(.volume(level: 0.55, muted: false), duration: 0.5) })], duration: 1.0),
            Scenario(name: "16-alert-claude", setup: compact,
                     steps: [(0, { $0.showAlert(.claudeFinished(id: "x", name: "Rebuild the notch island", duration: 734), duration: 0.5) })],
                     duration: 1.0),
            Scenario(name: "17-open-then-close", setup: compact, steps: [(0, home), (0.09, { $0.collapse() })], duration: 0.7),
            Scenario(name: "18-close-then-open", setup: home, steps: [(0, { $0.collapse() }), (0.09, home)], duration: 0.7),
            Scenario(name: "19-drop", setup: compact, steps: [(0, { $0.openDrop() }), (0.4, { $0.collapse() })], duration: 0.9),
            Scenario(name: "20-open-bubble", setup: compact, steps: [(0, { $0.expandSecondary() })]),
            Scenario(name: "21-alert-then-hover-open", setup: compact,
                     steps: [(0, { $0.showAlert(.volume(level: 0.4, muted: false), duration: 2) }), (0.15, { $0.expand(.glance, sticky: true) })],
                     duration: 0.7),
            Scenario(name: "22-home-to-search", setup: home, steps: [(0, { $0.openSearch() })]),
        ]
        if !claudeLive { scenarios.removeAll { $0.name.hasPrefix("16") } }
        // ATOLL_SCENARIOS=16,21 runs only the scenarios whose names start with those prefixes.
        if let only = ProcessInfo.processInfo.environment["ATOLL_SCENARIOS"]?.split(separator: ",").map(String.init), !only.isEmpty {
            scenarios.removeAll { s in !only.contains { s.name.hasPrefix($0) } }
        }
        print("transitions: live = \(controller.model.live.map(\.rawValue)), \(scenarios.count) scenarios")

        var t = 0.0
        for s in scenarios {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                let model = controller.model
                s.setup(model)
                // Let the starting state settle completely before recording.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                    self.capture(controller: controller, name: s.name, seconds: s.duration)
                    self.log(model, name: s.name, until: CACurrentMediaTime() + s.duration)
                    for (at, step) in s.steps {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 + at) { step(model) }
                    }
                }
            }
            t += 0.9 + s.duration + 0.5
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + t + 0.5) {
            NowPlayingModel.shared.debugInject(title: "", artist: "", duration: 0, elapsed: 0, artwork: nil, playing: false)
            if startedTimer { FocusTimer.shared.stop() }
            controller.model.collapse()
            print("transitions: done → \(self.outDir)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
    }

    /// Prints every change of state during a scenario, with its time.
    private func log(_ model: IslandModel, name: String, until end: CFTimeInterval, start: CFTimeInterval = CACurrentMediaTime()) {
        withObservationTracking { _ = model.mode; _ = model.alert } onChange: {
            DispatchQueue.main.async {
                let now = CACurrentMediaTime()
                guard now < end else { return }
                print(String(format: "  %@ %4.0f ms  mode %@  alert %@", name, (now - start) * 1000, "\(model.mode)",
                             model.alert.map { "\($0.kind)" } ?? "nil"))
                self.log(model, name: name, until: end, start: start)
            }
        }
    }

    private func capture(controller: IslandController, name: String, seconds: Double) {
        guard let handle = dlopen(nil, RTLD_NOW), let sym = dlsym(handle, "CGWindowListCreateImage") else { return }
        let fn = unsafeBitCast(sym, to: CaptureFn.self)
        let f = controller.panel.frame
        let top = NSScreen.screens.first?.frame.maxY ?? f.maxY
        let rect = CGRect(x: f.minX, y: top - f.maxY, width: f.width, height: f.height)
        let window = UInt32(controller.panel.windowNumber)
        let dir = (outDir as NSString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let frames = Int(seconds * 60)
        DispatchQueue.global(qos: .userInitiated).async {
            let start = CACurrentMediaTime()
            var shots: [(Int, CGImage)] = []
            for i in 0..<frames {
                let wait = start + Double(i) / 60 - CACurrentMediaTime()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                // kCGWindowListOptionIncludingWindow = 8 (this window only), best resolution = 0.
                guard let img = fn(rect, 8, window, 0)?.takeRetainedValue() else { continue }
                shots.append((Int((CACurrentMediaTime() - start) * 1000), img))
            }
            // Encode after capturing, so encoding never delays a frame.
            for (i, shot) in shots.enumerated() {
                try? NSBitmapImageRep(cgImage: shot.1).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: dir).appendingPathComponent(String(format: "%02d-%04dms.png", i, shot.0)))
            }
        }
    }
}
#endif
