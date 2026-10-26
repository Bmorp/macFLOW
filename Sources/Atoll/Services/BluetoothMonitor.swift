import AppKit
import IOBluetooth
import CoreBluetooth

/// AirPods / headphones / keyboards connecting — shown as a live activity with battery levels.
/// Opt-in: registering for Bluetooth events asks for Bluetooth permission once.
@MainActor
final class BluetoothMonitor: NSObject {
    static let shared = BluetoothMonitor()

    struct Device: Equatable {
        let name: String
        let symbol: String
        let single: Int?
        let left: Int?
        let right: Int?
        let caseLevel: Int?
        let connected: Bool

        var hasBattery: Bool { single != nil || left != nil || right != nil }
    }

    var onChange: ((Device) -> Void)?

    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [IOBluetoothUserNotification] = []
    private var started = false
    private var startedAt = Date()
    /// Asks for Bluetooth permission off the main thread (see `setEnabled`).
    private var authProbe: CBCentralManager?
    private static let probeQueue = DispatchQueue(label: "atoll.bluetooth.auth")

    func setEnabled(_ on: Bool) {
        if on, !started {
            started = true
            startedAt = Date()
            // IOBluetooth waits for the permission answer on whatever thread first touches it. On the main thread that
            // froze the whole island behind the prompt (every new unsigned build is a new app to macOS, so it asks again).
            switch CBManager.authorization {
            case .allowedAlways: register()
            case .notDetermined:
                authProbe = CBCentralManager(delegate: self, queue: Self.probeQueue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
            default: break   // denied or restricted: no device alerts
            }
        } else if !on, started {
            started = false
            authProbe = nil
            connectNote?.unregister()
            connectNote = nil
            disconnectNotes.forEach { $0.unregister() }
            disconnectNotes.removeAll()
        }
    }

    private func register() {
        guard started, connectNote == nil else { return }
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(connected(_:device:)))
    }

    @objc private func connected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let n = device.register(forDisconnectNotification: self, selector: #selector(disconnected(_:device:))) {
            disconnectNotes.append(n)
        }
        // Registration replays already-connected devices; only announce genuinely new connections.
        guard Date().timeIntervalSince(startedAt) > 3 else { return }
        // Battery levels arrive a moment after the link comes up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
            self?.onChange?(Self.describe(device, connected: true))
        }
    }

    @objc private func disconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        disconnectNotes.removeAll { $0 === note }
        onChange?(Self.describe(device, connected: false))
    }

    /// Devices connected right now, with batteries where they report them.
    static func connectedDevices() -> [Device] {
        guard Prefs.shared.devices else { return [] }
        return (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
            .filter { $0.isConnected() }
            .map { describe($0, connected: true) }
            .filter(\.hasBattery)
    }

    private static func describe(_ d: IOBluetoothDevice, connected: Bool) -> Device {
        let name = d.name ?? "Bluetooth device"
        return Device(name: name,
                      symbol: symbol(for: d, name: name),
                      single: battery(d, "batteryPercentSingle") ?? battery(d, "batteryPercentCombined"),
                      left: battery(d, "batteryPercentLeft"),
                      right: battery(d, "batteryPercentRight"),
                      caseLevel: battery(d, "batteryPercentCase"),
                      connected: connected)
    }

    /// Battery levels are undocumented properties; only read them when the object really has them.
    private static func battery(_ d: IOBluetoothDevice, _ key: String) -> Int? {
        guard d.responds(to: NSSelectorFromString(key)),
              let v = d.value(forKey: key) as? NSNumber, v.intValue > 0, v.intValue <= 100 else { return nil }
        return v.intValue
    }

    private static func symbol(for d: IOBluetoothDevice, name: String) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("beats") { return "beats.headphones" }
        if n.contains("keyboard") { return "keyboard" }
        if n.contains("trackpad") { return "rectangle.and.hand.point.up.left" }
        if n.contains("mouse") { return "magicmouse" }
        if n.contains("controller") || n.contains("dualsense") || n.contains("xbox") { return "gamecontroller.fill" }
        switch d.deviceClassMajor {
        case UInt32(kBluetoothDeviceClassMajorAudio): return "headphones"
        case UInt32(kBluetoothDeviceClassMajorPeripheral): return "keyboard"
        case UInt32(kBluetoothDeviceClassMajorPhone): return "iphone"
        default: return "dot.radiowaves.left.and.right"
        }
    }
}

extension BluetoothMonitor: CBCentralManagerDelegate {
    /// The person answered the permission prompt (or the radio changed): register once it's allowed.
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard CBManager.authorization == .allowedAlways else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                BluetoothMonitor.shared.authProbe = nil
                BluetoothMonitor.shared.register()
            }
        }
    }
}
