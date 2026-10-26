#if DEBUG
import AppKit
import Observation

/// Debug: drives the real island with a scripted, virtual pointer (the real cursor is never moved) along the paths
/// a hand actually takes, and checks every open/close decision against what should happen.
@MainActor
final class HoverTest {
    static var current: HoverTest?
    private var c: IslandController!
    private var events: [(t: Double, mode: String)] = []
    private var t0 = CACurrentMediaTime()
    private var results: [(String, Bool, String)] = []

    static func schedule() {
        IslandManager.suppressAlerts = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            let test = HoverTest()
            current = test
            test.run()
        }
    }

    private var top: CGFloat { c.screen.frame.maxY }
    private var mid: CGFloat { c.screen.frame.midX }
    private var notchH: CGFloat { c.model.notch.height }

    private func run() {
        guard let controller = IslandManager.shared.primary else { print("hover test: no island"); exit(1) }
        c = controller
        watchMode()
        Task { await scenarios(); finish() }
    }

    /// Logs every change of state (the model is Observable: the change is reported just before it lands).
    private func watchMode() {
        withObservationTracking { _ = c.model.mode } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.events.append((CACurrentMediaTime() - self.t0, "\(self.c.model.mode)"))
                self.watchMode()
            }
        }
    }

    // MARK: Pointer

    private func set(_ p: NSPoint) {
        IslandController.pointerOverride = p
        c.evaluateMouse()
    }

    /// Moves along a straight line at a given speed (pt/s), 120 samples a second.
    private func move(from a: NSPoint, to b: NSPoint, speed: CGFloat) async {
        let d = hypot(b.x - a.x, b.y - a.y)
        let steps = max(1, Int(d / speed * 120))
        for i in 0...steps {
            let f = CGFloat(i) / CGFloat(steps)
            set(NSPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f))
            try? await Task.sleep(nanoseconds: 8_333_333)
        }
    }

    private func rest(_ seconds: Double, at p: NSPoint) async {
        let end = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < end {
            set(p)
            try? await Task.sleep(nanoseconds: 33_000_000)
        }
    }

    private var away: NSPoint { NSPoint(x: mid - 420, y: top - 420) }
    private var onNotch: NSPoint { NSPoint(x: mid + 40, y: top - notchH / 2) }

    private func reset() async {
        if c.model.mode == .alert { c.model.dismissAlert() }
        c.model.collapse()
        await rest(0.8, at: away)
        events.removeAll()
        t0 = CACurrentMediaTime()
    }

    private func opened() -> Bool { events.contains { $0.mode.hasPrefix("expanded") } }
    private func firstOpen() -> Double? { events.first { $0.mode.hasPrefix("expanded") }?.t }
    private func check(_ name: String, _ ok: Bool, _ detail: String) {
        results.append((name, ok, detail))
        print(String(format: "%@ %@ — %@", ok ? "PASS" : "FAIL", name, detail))
    }

    // MARK: Scenarios

    private func scenarios() async {
        // 1. Sweeping across the top to reach the menu bar: must not open.
        await reset()
        await move(from: NSPoint(x: mid - 400, y: top - 6), to: NSPoint(x: mid + 400, y: top - 6), speed: 1400)
        await rest(0.5, at: NSPoint(x: mid + 400, y: top - 6))
        check("pass-through to menu bar", !opened(), opened() ? "opened at \(String(format: "%.2f", firstOpen() ?? 0)) s" : "stayed closed")

        // 2. Moving up to the notch and resting: opens Home promptly.
        await reset()
        await move(from: NSPoint(x: mid + 40, y: top - 300), to: onNotch, speed: 900)
        let arrived = CACurrentMediaTime() - t0
        await rest(0.8, at: onNotch)
        let latency = (firstOpen() ?? 99) - arrived
        let home = events.contains { $0.mode == "expanded(Atoll.IslandFocus.glance)" }
        check("approach and rest opens Home", opened() && home && latency < Prefs.shared.hoverDelay + 0.2,
              String(format: "opened %.0f ms after arriving (hover delay %.0f ms)%@", latency * 1000, Prefs.shared.hoverDelay * 1000, home ? "" : ", not Home"))

        // 3. Grazing the notch for a moment: no open.
        await reset()
        await move(from: NSPoint(x: mid + 40, y: top - 200), to: onNotch, speed: 1200)
        await rest(0.05, at: onNotch)
        await move(from: onNotch, to: NSPoint(x: mid + 40, y: top - 200), speed: 1200)
        await rest(0.4, at: NSPoint(x: mid + 40, y: top - 200))
        check("graze doesn't open", !opened(), opened() ? "opened" : "stayed closed")

        // 4. Open, then leave: closes after a short grace; coming back within it keeps it open.
        await reset()
        await move(from: NSPoint(x: mid + 40, y: top - 300), to: onNotch, speed: 900)
        await rest(0.7, at: onNotch)
        let inside = NSPoint(x: mid, y: top - notchH - 40)
        await move(from: onNotch, to: inside, speed: 600)
        // Overshoot the bottom edge by 50 pt and come straight back (a real hand does this all the time).
        let edge = top - c.model.spec.size.height
        let beyond = NSPoint(x: mid, y: edge - 70)
        await move(from: inside, to: beyond, speed: 1500)
        await rest(0.08, at: beyond)
        await move(from: beyond, to: inside, speed: 1500)
        await rest(0.6, at: inside)
        let stayed = c.model.mode != .compact
        check("brief exit and return keeps it open", stayed, stayed ? "stayed open" : "closed under the pointer")
        await move(from: inside, to: away, speed: 1500)
        await rest(0.8, at: away)
        let closedAfterLeaving = c.model.mode == .compact
        check("leaving closes it", closedAfterLeaving, closedAfterLeaving ? "closed" : "still open (\(c.model.mode))")

        // 5. Close while the pointer rests on the notch (Esc, a click): must not reopen until the pointer leaves.
        await reset()
        await move(from: NSPoint(x: mid + 40, y: top - 300), to: onNotch, speed: 900)
        await rest(0.7, at: onNotch)
        c.model.collapse()
        let closedAt = CACurrentMediaTime() - t0
        await rest(1.0, at: onNotch)
        let reopened = events.contains { $0.t > closedAt && $0.mode.hasPrefix("expanded") }
        check("closing under a resting pointer stays closed", !reopened, reopened ? "reopened by itself" : "stayed closed")

        // 5b. …and after leaving, coming back opens it again.
        await move(from: onNotch, to: away, speed: 1500)
        await rest(0.3, at: away)
        let back = CACurrentMediaTime() - t0
        await move(from: NSPoint(x: mid + 40, y: top - 300), to: onNotch, speed: 900)
        await rest(0.7, at: onNotch)
        let reopenedAfterExit = events.contains { $0.t > back && $0.mode.hasPrefix("expanded") }
        check("leaving and returning reopens it", reopenedAfterExit, reopenedAfterExit ? "reopened" : "stayed closed")

        // 5c. A menu open from the island holds it open while the pointer is over the menu.
        await reset()
        await move(from: NSPoint(x: mid + 40, y: top - 300), to: onNotch, speed: 900)
        await rest(0.7, at: onNotch)
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        await move(from: onNotch, to: away, speed: 1500)
        await rest(0.8, at: away)
        let heldByMenu = c.model.mode != .compact
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        await rest(0.8, at: away)
        check("an open menu holds the island", heldByMenu && c.model.mode == .compact,
              heldByMenu ? "held, then closed after the menu" : "closed under the menu")

        // 6. Switching tabs, then leaving: still closes (a tab isn't a pin).
        await reset()
        if c.model.tabs.count > 1 || true {
            await move(from: NSPoint(x: mid + 40, y: top - 300), to: onNotch, speed: 900)
            await rest(0.7, at: onNotch)
            c.model.select(.controls)
            await rest(0.5, at: NSPoint(x: mid, y: top - notchH - 40))
            await move(from: NSPoint(x: mid, y: top - notchH - 40), to: away, speed: 1500)
            await rest(0.8, at: away)
            check("after a tab switch, leaving closes it", c.model.mode == .compact, "\(c.model.mode)")
        }
    }

    private func finish() {
        IslandController.pointerOverride = nil
        let failed = results.filter { !$0.1 }.count
        print("hover test: \(results.count - failed)/\(results.count) passed")
        exit(failed == 0 ? 0 : 2)
    }
}
#endif
