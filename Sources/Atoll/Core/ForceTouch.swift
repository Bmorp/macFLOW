import AppKit
import SwiftUI

/// Force Touch, read honestly. There is no API that says a Force Touch trackpad is attached, and people can turn
/// Force Click off, so Mac Flow learns it the first time pressure arrives and keeps "press harder" hints hidden until
/// then. Everything here works the same with a mouse; pressure only adds to it.
///
/// For a deep press on a view (the island's peek): give the view `ForceTouch.deepClick` as its
/// `pressureConfiguration` while the pointer is over it, and in its `pressureChange(with:)` feed a
/// `ForcePressTracker` with `ForcePress(event)`. `towardDeep` drives a swell that follows the finger;
/// the tracker's `.deepened(2)` is the force click, `.released` the finger letting go. The trackpad plays the
/// force click itself: add no haptic.
@MainActor
final class ForceTouch: ObservableObject {
    static let shared = ForceTouch()
    private static let seenKey = "forceTouchSeen"

    /// A press that toggles between a click and a force click (stage 2), with the system's click at each.
    static let deepClick = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)

    /// Whether this Mac has ever reported pressure, which only a Force Touch trackpad does. Remembered across launches.
    @Published private(set) var seen: Bool

    init() {
        seen = UserDefaults.standard.bool(forKey: Self.seenKey)
    }

    /// Force Click as set in System Settings › Trackpad (on unless it's been turned off).
    var forceClickEnabled: Bool {
        UserDefaults.standard.object(forKey: "com.apple.trackpad.forceClick") as? Bool ?? true
    }

    /// Whether UI should mention pressing harder.
    var hintsVisible: Bool { seen && forceClickEnabled }

    /// Starts listening for the first pressure event. Cheap; safe to call often.
    func start() { HapticInput.shared.start() }

    /// Any pressure event, from the app-wide monitor or from a view's own `pressureChange(with:)`.
    func note(_ event: NSEvent) {
        guard !seen, event.type == .pressure else { return }
        seen = true
        UserDefaults.standard.set(true, forKey: Self.seenKey)
    }
}

/// One moment of a Force Touch press.
struct ForcePress: Sendable, Equatable {
    /// 0 released, 1 a click, 2 a force click. An accelerator button reports its level here instead (1…5).
    var stage: Int
    /// Pressure within the current stage, 0…1.
    var pressure: Double
    /// −1…1. Positive while pressing toward the next stage, negative while easing back toward the one below.
    var stageTransition: Double

    init(stage: Int, pressure: Double, stageTransition: Double = 0) {
        self.stage = max(0, stage)
        self.pressure = min(max(pressure, 0), 1)
        self.stageTransition = min(max(stageTransition, -1), 1)
    }

    init(_ event: NSEvent) {
        self.init(stage: event.stage, pressure: Double(event.pressure), stageTransition: Double(event.stageTransition))
    }

    /// How far the press has gone toward a force click, 0…1: 0 at a click, rising as the finger presses toward
    /// stage 2, 1 at the force click, falling as it eases off. Drive a swell with it, 1:1.
    var towardDeep: Double {
        switch stage {
        case ...0: 0
        case 1: max(0, stageTransition)
        default: 1 + min(0, stageTransition)
        }
    }

    /// The whole press as one number, 0…1, across `stages` stages.
    func normalized(stages: Int) -> Double {
        guard stage > 0, stages > 0 else { return 0 }
        return min(1, max(0, (Double(min(stage, stages) - 1) + pressure) / Double(stages)))
    }
}

/// Turns a stream of pressure readings into the moments that matter: pressed, deepened to a stage, eased back to one,
/// released.
struct ForcePressTracker: Sendable, Equatable {
    enum Change: Sendable, Equatable {
        case pressed
        case deepened(Int)
        case eased(Int)
        case released
    }

    private(set) var stage = 0
    /// The deepest stage this press reached; resets on release.
    private(set) var deepest = 0

    mutating func update(_ press: ForcePress) -> Change? {
        let old = stage
        guard press.stage != old else { return nil }
        stage = press.stage
        if press.stage == 0 {
            deepest = 0
            return .released
        }
        deepest = max(deepest, press.stage)
        if old == 0 { return press.stage == 1 ? .pressed : .deepened(press.stage) }
        return press.stage > old ? .deepened(press.stage) : .eased(press.stage)
    }
}

/// A press target that goes faster the harder you press: AppKit's multi-level accelerator button, drawing nothing,
/// laid over whatever SwiftUI draws. A click or a held mouse button is level 1; on a Force Touch trackpad, pressing
/// harder reaches levels 2…`levels`, and the trackpad plays its own click at each, so nothing here adds a haptic.
struct ForceAccelerator: NSViewRepresentable {
    var levels = 5
    let label: String
    var help: String?
    /// The level as it changes: 1…`levels` while pressed, 0 on release. A VoiceOver press is 1 then 0.
    let onLevel: (Int) -> Void

    func makeNSView(context: Context) -> AcceleratorButton {
        ForceTouch.shared.start()
        return AcceleratorButton()
    }

    func updateNSView(_ button: AcceleratorButton, context: Context) {
        button.onLevel = onLevel
        button.maxAcceleratorLevel = min(max(levels, 1), 5)
        button.setAccessibilityLabel(label)
        button.toolTip = help
    }

    final class AcceleratorButton: NSButton {
        var onLevel: ((Int) -> Void)?
        private var level = 0
        private var tracking = false

        init() {
            super.init(frame: .zero)
            setButtonType(.multiLevelAccelerator)
            maxAcceleratorLevel = 5
            isBordered = false
            isTransparent = true
            title = ""
            focusRingType = .none
            isContinuous = true
            target = self
            action = #selector(changed)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        // The island and widgets are never the active app's key window; the first click must count.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            tracking = true
            report(1)
            super.mouseDown(with: event)   // AppKit tracks the press, pressure levels included, until release
            tracking = false
            report(0)
        }

        override func pressureChange(with event: NSEvent) {
            super.pressureChange(with: event)
            ForceTouch.shared.note(event)
            if tracking { report(max(1, integerValue)) }
        }

        @objc private func changed() {
            if tracking {
                // The click's own action on release isn't a level.
                guard NSApp.currentEvent?.type != .leftMouseUp else { return }
                report(max(1, integerValue))
            } else {
                // Pressed without the mouse (VoiceOver, accessibility): one step.
                onLevel?(1)
                onLevel?(0)
            }
        }

        private func report(_ l: Int) {
            let l = min(max(l, 0), maxAcceleratorLevel)
            guard l != level else { return }
            level = l
            onLevel?(l)
        }
    }
}
