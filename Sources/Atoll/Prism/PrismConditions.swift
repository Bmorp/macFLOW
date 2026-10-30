import AppKit
import Metal
import Combine

/// How much of Prism this Mac should draw right now, from most to least.
enum PrismTier: Int, Comparable, Sendable {
    /// The shaders aren't there (no Prism.metallib): every surface keeps its plain look.
    case off
    /// Thermal state critical: flat, no GPU material at all.
    case flat
    /// Thermal state serious, or an Intel / discrete-memory GPU: the material is drawn, nothing animates.
    case still
    /// Low Power Mode: 60 Hz at most, no dispersion, sparks hold still.
    case saver
    case full

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Everything that decides how Prism draws. A plain value, so the rules are one pure function (tested in PrismTests).
struct PrismEnvironment: Equatable, Sendable {
    var libraryLoaded: Bool
    var reduceTransparency = false
    var reduceMotion = false
    var increaseContrast = false
    var lowPower = false
    var thermal: ProcessInfo.ThermalState = .nominal
    /// Apple silicon. Intel Macs and discrete GPUs copy textures across a bus; they get the still material.
    var unifiedMemory = true

    var tier: PrismTier {
        guard libraryLoaded else { return .off }
        if thermal == .critical { return .flat }
        if thermal == .serious || !unifiedMemory { return .still }
        if lowPower { return .saver }
        return .full
    }

    /// Glass may look through to what's behind it. Reduce Transparency shades the strips over solid instead.
    var samplesBehind: Bool { !reduceTransparency }
    var dispersion: Bool { tier == .full && !reduceTransparency }
    /// Sparks run along their strip while numerals change (otherwise they hold still).
    var movingSparks: Bool { tier == .full }
    /// Ribbon numerals spring from one digit to the next. Without it a change is one new frame.
    var morphs: Bool { tier >= .saver && !reduceMotion }
    /// Reduce Motion: a 0.2 s cross-fade instead of the morph.
    var crossFades: Bool { tier >= .saver && reduceMotion }
    var maxFrameRate: Float { tier == .full ? 120 : 60 }
}

/// Watches the settings and machine state Prism depends on and publishes the result. Changes are rare (a setting,
/// Low Power Mode, the Mac heating up), so this is the only place that listens.
@MainActor
final class PrismConditions: ObservableObject {
    static let shared = PrismConditions()

    @Published private(set) var current: PrismEnvironment
    private var observers: [NSObjectProtocol] = []

    private init() {
        current = Self.read()
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PrismConditions.shared.refresh() }
        })
        let nc = NotificationCenter.default
        for name in [Notification.Name.NSProcessInfoPowerStateDidChange, ProcessInfo.thermalStateDidChangeNotification] {
            // Both arrive on arbitrary threads.
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PrismConditions.shared.refresh() }
            })
        }
    }

    func refresh() {
        let next = Self.read()
        if next != current { current = next }
    }

    nonisolated static func read() -> PrismEnvironment {
        let ws = NSWorkspace.shared
        let info = ProcessInfo.processInfo
        var env = PrismEnvironment(libraryLoaded: PrismLibrary.shared != nil)
        env.reduceTransparency = Self.override("ATOLL_PRISM_RT") ?? ws.accessibilityDisplayShouldReduceTransparency
        env.reduceMotion = Self.override("ATOLL_PRISM_RM") ?? ws.accessibilityDisplayShouldReduceMotion
        env.increaseContrast = ws.accessibilityDisplayShouldIncreaseContrast
        env.lowPower = info.isLowPowerModeEnabled || Self.forced("ATOLL_PRISM_LOWPOWER")
        env.thermal = Self.forcedThermal ?? info.thermalState
        env.unifiedMemory = (PrismLibrary.shared?.device.hasUnifiedMemory ?? true) && !Self.forced("ATOLL_PRISM_INTEL")
        return env
    }

    /// Debug switches, so the fallbacks can be checked on a Mac that isn't in that state (and the full look on one
    /// that is): "1" forces a setting on, "0" off.
    private nonisolated static func override(_ key: String) -> Bool? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment[key] {
        case "1": return true
        case "0": return false
        default: return nil
        }
        #else
        return nil
        #endif
    }

    private nonisolated static func forced(_ key: String) -> Bool { override(key) == true }

    private nonisolated static var forcedThermal: ProcessInfo.ThermalState? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["ATOLL_PRISM_THERMAL"] {
        case "serious": return .serious
        case "critical": return .critical
        default: return nil
        }
        #else
        return nil
        #endif
    }
}
