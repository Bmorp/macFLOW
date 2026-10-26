import Foundation
import IOKit.ps

/// Power source changes pushed from IOKit — powers the charging live activity.
@MainActor
final class BatteryMonitor: ObservableObject {
    static let shared = BatteryMonitor()

    @Published private(set) var level = 100
    @Published private(set) var isCharging = false
    @Published private(set) var onAC = true
    @Published private(set) var hasBattery = false
    @Published private(set) var minutesRemaining: Int?

    var onPluggedIn: ((Int) -> Void)?
    var onLow: ((Int) -> Void)?

    private var source: CFRunLoopSource?
    private var lowAlerted: Set<Int> = []

    init() {
        read(initial: true)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.read(initial: false) }
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
    }

    var symbol: String {
        if onAC && isCharging { return "battery.100percent.bolt" }
        switch level {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    func read(initial: Bool) {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else { return }
        let providing = IOPSGetProvidingPowerSourceType(snap)?.takeUnretainedValue() as String?
        let wasAC = onAC
        let nowAC = providing == kIOPSACPowerValue

        for ps in list {
            guard let desc = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any],
                  (desc[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            if !hasBattery { hasBattery = true }
            let cur = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = desc[kIOPSMaxCapacityKey] as? Int ?? 100
            let pct = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            if pct != level { level = pct }
            let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
            if charging != isCharging { isCharging = charging }
            let tte = desc[kIOPSTimeToEmptyKey] as? Int ?? -1
            let minutes = tte > 0 ? tte : nil
            if minutes != minutesRemaining { minutesRemaining = minutes }
        }
        if nowAC != onAC { onAC = nowAC }

        guard hasBattery, !initial else { return }
        if nowAC && !wasAC { onPluggedIn?(level) }
        if nowAC {
            lowAlerted.removeAll()
        } else {
            for threshold in [10, 20] where level <= threshold && !lowAlerted.contains(threshold) {
                lowAlerted.formUnion([10, 20].filter { $0 >= threshold })
                onLow?(level)
                break
            }
        }
    }
}
