import Foundation
import SwiftUI

/// Pomodoro-style focus timer that lives in the notch while it runs.
@MainActor
final class FocusTimer: ObservableObject {
    static let shared = FocusTimer()

    enum Phase { case idle, running, paused }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var total: TimeInterval = 25 * 60
    @Published private(set) var remaining: TimeInterval = 25 * 60
    @Published private(set) var label = "Focus"

    var onFinish: ((String) -> Void)?
    /// Any end — finished or stopped early — with the timer's label (a room is saved as it was).
    var onStop: ((String) -> Void)?

    private var endDate: Date?
    private var ticker: Timer?

    static let presets: [(minutes: Int, label: String)] = [(5, "Break"), (15, "Sprint"), (25, "Focus"), (50, "Deep Work")]

    var isActive: Bool { phase != .idle }
    var progress: Double { total > 0 ? min(1, max(0, 1 - remaining / total)) : 0 }

    var clock: String {
        let s = Int(remaining.rounded(.up))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    func start(minutes: Int, label: String) {
        total = TimeInterval(minutes * 60)
        remaining = total
        self.label = label
        endDate = Date().addingTimeInterval(total)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { phase = .running }
        startTicker()
    }

    func togglePause() {
        switch phase {
        case .running:
            ticker?.invalidate()
            remaining = max(0, endDate?.timeIntervalSinceNow ?? remaining)
            withAnimation { phase = .paused }
        case .paused:
            endDate = Date().addingTimeInterval(remaining)
            withAnimation { phase = .running }
            startTicker()
        case .idle: break
        }
    }

    func stop() {
        let ended = phase != .idle ? label : nil
        ticker?.invalidate()
        ticker = nil
        endDate = nil
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            phase = .idle
            remaining = total
        }
        if let ended { onStop?(ended) }
    }

    func add(minutes: Int) {
        let delta = TimeInterval(minutes * 60)
        total += delta
        remaining += delta
        if let e = endDate { endDate = e.addingTimeInterval(delta) }
    }

    /// One tick per displayed second, landing just after the clock's figure changes (it used to poll four
    /// times a second to catch the change).
    private func startTicker() {
        ticker?.invalidate()
        ticker = nil
        tick()
        guard phase == .running, let endDate else { return }
        let left = endDate.timeIntervalSinceNow
        let t = Timer(fire: Date().addingTimeInterval(left - floor(left) + 0.01), interval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    private func tick() {
        guard phase == .running, let endDate else { return }
        let left = endDate.timeIntervalSinceNow
        if left <= 0 {
            remaining = 0
            let finished = label
            stop()
            onFinish?(finished)
        } else if Int(left.rounded(.up)) != Int(remaining.rounded(.up)) {
            remaining = left
        }
    }
}
