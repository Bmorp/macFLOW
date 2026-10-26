import AppKit
import CoreGraphics

/// The built-in display and keyboard: brightness, Night Shift, True Tone and the keyboard backlight.
/// macOS has no public API for these, so — like the system's own Control Center — Atoll uses the private
/// DisplayServices and CoreBrightness frameworks, loaded at run time. Anything a Mac doesn't support simply
/// doesn't appear.
@MainActor
final class DisplayControl: ObservableObject {
    static let shared = DisplayControl()

    @Published private(set) var brightness: Double = 0.5
    @Published private(set) var canSetBrightness = false
    @Published private(set) var nightShift = false
    @Published private(set) var hasNightShift = false
    @Published private(set) var trueTone = false
    @Published private(set) var hasTrueTone = false
    @Published private(set) var keyboard: Double = 0
    @Published private(set) var hasKeyboard = false

    private typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
    private var getBrightness: GetBrightness?
    private var setBrightnessFn: SetBrightness?
    private var blueLight: NSObject?
    private var trueToneClient: NSObject?
    private var keyboardClient: NSObject?
    private var keyboardID: UInt64 = 1
    private var keyMonitors: [Any] = []
    private var lastOwnChange = Date.distantPast

    private var display: UInt32 {
        // The built-in panel if there is one, else the main display.
        var ids = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(8, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    func start() {
        guard getBrightness == nil else { return }
        if let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) {
            getBrightness = dlsym(ds, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetBrightness.self) }
            setBrightnessFn = dlsym(ds, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: SetBrightness.self) }
        }
        if dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW) != nil {
            blueLight = (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()
            trueToneClient = (NSClassFromString("CBTrueToneClient") as? NSObject.Type)?.init()
            keyboardClient = (NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type)?.init()
            if let kb = keyboardClient, kb.responds(to: NSSelectorFromString("copyKeyboardBacklightIDs")),
               let ids = kb.perform(NSSelectorFromString("copyKeyboardBacklightIDs"))?.takeRetainedValue() as? [NSNumber], let first = ids.first {
                keyboardID = first.uint64Value
            }
        }
        refresh()
        watchKeys()
    }

    /// Re-read everything (called when the controls come on screen and after brightness keys). The reads are calls into
    /// private frameworks over IPC — 20–40 ms on the main thread, a visible hitch just as Controls settled open — so
    /// they run on a queue of their own, and only what changed is published.
    func refresh() {
        guard !reading else { refreshAgain = true; return }
        reading = true
        let clients = Clients(getBrightness: getBrightness, canSet: setBrightnessFn != nil, display: display,
                              blueLight: blueLight, trueTone: trueToneClient, keyboard: keyboardClient, keyboardID: keyboardID)
        readQueue.async {
            let r = Self.read(clients)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = DisplayControl.shared
                    me.apply(r)
                    me.reading = false
                    if me.refreshAgain { me.refreshAgain = false; me.refresh() }
                }
            }
        }
    }

    private let readQueue = DispatchQueue(label: "atoll.display.read", qos: .userInitiated)
    private var reading = false
    private var refreshAgain = false

    private struct Clients: @unchecked Sendable {
        let getBrightness: GetBrightness?
        let canSet: Bool
        let display: UInt32
        let blueLight: NSObject?
        let trueTone: NSObject?
        let keyboard: NSObject?
        let keyboardID: UInt64
    }

    private struct Reading: Sendable {
        var brightness: Double?
        var canSetBrightness = false
        var nightShift: Bool?
        var trueTone: (supported: Bool, on: Bool)?
        var keyboard: (supported: Bool, level: Double)?
    }

    nonisolated private static func read(_ c: Clients) -> Reading {
        var r = Reading()
        if let get = c.getBrightness {
            var b: Float = 0
            if get(c.display, &b) == 0 {
                r.brightness = Double(b)
                r.canSetBrightness = c.canSet
            }
        }
        if let bl = c.blueLight {
            var status = [UInt8](repeating: 0, count: 64)
            let sel = NSSelectorFromString("getBlueLightStatus:")
            if bl.responds(to: sel) {
                typealias F = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
                // CBBlueLightStatus: { BOOL active; BOOL enabled; … } — "enabled" is whether it's on right now.
                if unsafeBitCast(bl.method(for: sel), to: F.self)(bl, sel, &status) { r.nightShift = status[1] != 0 }
            }
        }
        if let tt = c.trueTone {
            r.trueTone = (bool(tt, "supported") && bool(tt, "available"), bool(tt, "enabled"))
        }
        if let kb = c.keyboard {
            let sel = NSSelectorFromString("brightnessForKeyboard:")
            if kb.responds(to: sel) {
                typealias F = @convention(c) (AnyObject, Selector, UInt64) -> Float
                let v = unsafeBitCast(kb.method(for: sel), to: F.self)(kb, sel, c.keyboardID)
                r.keyboard = (kb.responds(to: NSSelectorFromString("setBrightness:forKeyboard:")), Double(v))
            }
        }
        return r
    }

    private func apply(_ r: Reading) {
        if let b = r.brightness {
            if canSetBrightness != r.canSetBrightness { canSetBrightness = r.canSetBrightness }
            if abs(b - brightness) > 0.002 { brightness = b }
        }
        if let n = r.nightShift {
            if !hasNightShift { hasNightShift = true }
            if nightShift != n { nightShift = n }
        }
        if let t = r.trueTone {
            if hasTrueTone != t.supported { hasTrueTone = t.supported }
            if trueTone != t.on { trueTone = t.on }
        }
        if let k = r.keyboard {
            if hasKeyboard != k.supported { hasKeyboard = k.supported }
            if abs(keyboard - k.level) > 0.002 { keyboard = k.level }
        }
    }

    func setBrightness(_ value: Double) {
        let v = min(1, max(0, value))
        lastOwnChange = Date()
        _ = setBrightnessFn?(display, Float(v))
        brightness = v
    }

    func setNightShift(_ on: Bool) {
        guard let bl = blueLight else { return }
        let sel = NSSelectorFromString("setEnabled:")
        typealias F = @convention(c) (AnyObject, Selector, Bool) -> Bool
        if bl.responds(to: sel) { _ = unsafeBitCast(bl.method(for: sel), to: F.self)(bl, sel, on) }
        nightShift = on
    }

    func setTrueTone(_ on: Bool) {
        guard let tt = trueToneClient else { return }
        let sel = NSSelectorFromString("setEnabled:")
        typealias F = @convention(c) (AnyObject, Selector, Bool) -> Bool
        if tt.responds(to: sel) { _ = unsafeBitCast(tt.method(for: sel), to: F.self)(tt, sel, on) }
        trueTone = on
    }

    func setKeyboard(_ value: Double) {
        guard let kb = keyboardClient else { return }
        let v = Float(min(1, max(0, value)))
        let sel = NSSelectorFromString("setBrightness:forKeyboard:")
        typealias F = @convention(c) (AnyObject, Selector, Float, UInt64) -> Bool
        if kb.responds(to: sel) { _ = unsafeBitCast(kb.method(for: sel), to: F.self)(kb, sel, v, keyboardID) }
        keyboard = Double(v)
    }

    nonisolated private static func bool(_ o: NSObject, _ name: String) -> Bool {
        let sel = NSSelectorFromString(name)
        guard o.responds(to: sel) else { return false }
        typealias F = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(o.method(for: sel), to: F.self)(o, sel)
    }

    /// Brightness keys: re-read just after the system applies the change, so the island can show it.
    private func watchKeys() {
        let handler: (NSEvent) -> Void = { e in
            // NX_SYSDEFINED subtype 8 carries media keys; 2/3 are brightness up/down.
            guard e.type == .systemDefined, e.subtype.rawValue == 8 else { return }
            let key = (e.data1 & 0xFFFF0000) >> 16
            let down = ((e.data1 & 0xFF00) >> 8) == 0xA
            guard down, key == 2 || key == 3 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                MainActor.assumeIsolated { DisplayControl.shared.keyChanged() }
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined, handler: handler) { keyMonitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .systemDefined, handler: { handler($0); return $0 }) { keyMonitors.append(l) }
    }

    /// A brightness key changed the display — not Atoll's own slider.
    @Published private(set) var keyTick = 0
    private func keyChanged() {
        refresh()
        if Date().timeIntervalSince(lastOwnChange) > 0.5 { keyTick += 1 }
    }
}
