import AppKit
import IOKit

/// The Force Touch trackpad's motor, driven directly.
///
/// macOS plays `NSHapticFeedbackManager`'s patterns only for the app in front, and Mac Flow never is: the notch panel
/// doesn't activate it, so every standard haptic was dropped. (Measured on a MacBook: the standard call, `.now` or
/// `.drawCompleted`, was never felt; the actuator was.) So haptics go to the trackpad's actuator through
/// MultitouchSupport, a private framework loaded at run time. If it isn't there, or no trackpad opens, `available`
/// is false and the engine falls back to the standard call.
@MainActor
final class TrackpadActuator {
    static let shared = TrackpadActuator()

    /// Actuation waveforms, from the motor's own table. Tuned by hand on a MacBook: 1–5 are felt but soft; 6 is the
    /// crisp one, and it's right for scroll steps as well as moments, so both use it for now.
    struct Strength: Sendable {
        let id: Int32
        static let tick = Strength(id: 6)
        static let firm = Strength(id: 6)
    }

    private typealias Create = @convention(c) (UInt64) -> Unmanaged<AnyObject>?
    private typealias Open = @convention(c) (AnyObject) -> Int32
    private typealias Actuate = @convention(c) (AnyObject, Int32, UInt32, Float, Float) -> Int32

    private var create: Create?
    private var open: Open?
    private var actuate: Actuate?
    private var actuators: [AnyObject] = []
    private var lastOpen: TimeInterval = -.infinity

    var available: Bool { !actuators.isEmpty }

    private init() {
        guard !RenderMode.snapshot,
              let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let c = dlsym(lib, "MTActuatorCreateFromDeviceID"), let o = dlsym(lib, "MTActuatorOpen"),
              let a = dlsym(lib, "MTActuatorActuate") else { return }
        create = unsafeBitCast(c, to: Create.self)
        open = unsafeBitCast(o, to: Open.self)
        actuate = unsafeBitCast(a, to: Actuate.self)
        reopen()
        // After sleep the motor's handle can go stale, and a Magic Trackpad may have arrived: look again on wake.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                TrackpadActuator.shared.lastOpen = -.infinity
                TrackpadActuator.shared.reopen()
            }
        }
    }

    /// Plays one actuation on every Force Touch trackpad attached (the built-in one, a Magic Trackpad).
    func play(_ strength: Strength) {
        guard let actuate else { return }
        var failed = false
        for a in actuators where actuate(a, strength.id, 0, 0, 0) != 0 { failed = true }
        // A trackpad that went away (a Magic Trackpad switched off) or one that arrived: look again, at most once a
        // few seconds, never per haptic.
        if failed { reopen() }
    }

    private func reopen() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastOpen > 3, let create, let open else { return }
        lastOpen = now
        actuators.removeAll()
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleMultitouchDevice"), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while case let service = IOIteratorNext(it), service != 0 {
            defer { IOObjectRelease(service) }
            guard let id = IORegistryEntryCreateCFProperty(service, "Multitouch ID" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? NSNumber,
                  let actuator = create(id.uint64Value)?.takeRetainedValue(),
                  open(actuator) == 0 else { continue }
            actuators.append(actuator)
        }
    }
}
