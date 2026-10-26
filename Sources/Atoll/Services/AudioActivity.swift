import AppKit
import CoreAudio
import CoreMediaIO

/// An app that is currently producing (or capturing) audio.
struct AudioApp: Identifiable, Equatable {
    let id: String          // bundle identifier
    let name: String
    let url: URL?

    @MainActor var icon: NSImage? { url.map { IconCache.file($0.path) } }

    func activate() {
        NSRunningApplication.runningApplications(withBundleIdentifier: id).first?.activate()
    }
}

/// Watches system audio through public CoreAudio / CoreMediaIO APIs (no permissions):
/// which apps are playing sound, and whether the microphone or camera is live.
@MainActor
final class AudioActivity: ObservableObject {
    static let shared = AudioActivity()

    @Published private(set) var playing: [AudioApp] = []
    @Published private(set) var micApps: [AudioApp] = []
    @Published private(set) var micInUse = false
    @Published private(set) var cameraInUse = false

    /// Set while Atoll's own Mirror is using the camera so we don't flag ourselves.
    var suppressCamera = false

    private var detailTimer: Timer?
    private var cameraFallback: Timer?
    private var appCache: [pid_t: AudioApp?] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private var watchedDevices: [(AudioObjectID, AudioObjectPropertyAddress)] = []
    private var watchedCameras = Set<CMIOObjectID>()
    private lazy var deviceChanged: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { self?.refreshAudio() }
    }

    /// Event-driven: CoreAudio and CoreMediaIO tell us when a device starts or stops.
    /// The per-app list is only read while something is actually running.
    init() {
        var outDefault = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        var inDefault = Self.address(kAudioHardwarePropertyDefaultInputDevice)
        let system = AudioObjectID(kAudioObjectSystemObject)
        let rewire: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            DispatchQueue.main.async { self?.watchDefaultDevices() }
        }
        AudioObjectAddPropertyListenerBlock(system, &outDefault, DispatchQueue.main, rewire)
        AudioObjectAddPropertyListenerBlock(system, &inDefault, DispatchQueue.main, rewire)
        watchDefaultDevices()
        watchCameras()
        // New cameras are rare; a slow sweep catches them without a per-second cost.
        let t = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchCameras() }
        }
        t.tolerance = 3
        RunLoop.main.add(t, forMode: .common)
        cameraFallback = t
    }

    nonisolated private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private func watchDefaultDevices() {
        for (device, addr) in watchedDevices {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(device, &a, DispatchQueue.main, deviceChanged)
        }
        watchedDevices.removeAll()
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            guard let device = Self.defaultDevice(selector) else { continue }
            var a = Self.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectAddPropertyListenerBlock(device, &a, DispatchQueue.main, deviceChanged)
            watchedDevices.append((device, a))
        }
        refreshAudio()
    }

    private var scanning = false

    private func refreshAudio() {
        let outputRunning = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice).map(Self.isRunning) ?? false
        let inputRunning = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice).map(Self.isRunning) ?? false
        if inputRunning != micInUse { micInUse = inputRunning }

        guard outputRunning || inputRunning else {
            if !playing.isEmpty { playing = [] }
            if !micApps.isEmpty { micApps = [] }
            detailTimer?.invalidate()
            detailTimer = nil
            return
        }
        // The process list is an IPC round trip to coreaudiod — never on the main thread.
        if #available(macOS 14.2, *), !scanning {
            scanning = true
            DispatchQueue.global(qos: .utility).async {
                let (out, inp) = Self.processActivity()
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let me = AudioActivity.shared
                        me.scanning = false
                        let outApps = me.dedupe(out.compactMap(me.resolve))
                        let inApps = me.dedupe(inp.compactMap(me.resolve))
                        if outApps != me.playing { me.playing = outApps }
                        if inApps != me.micApps { me.micApps = inApps }
                    }
                }
            }
        }
        // While audio runs, which app is playing can change without the device stopping.
        if detailTimer == nil {
            let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAudio() }
            }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            detailTimer = t
        }
    }

    private func watchCameras() {
        for device in Self.cameraDevices() where !watchedCameras.contains(device) {
            var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            CMIOObjectAddPropertyListenerBlock(device, &a, DispatchQueue.main) { [weak self] _, _ in
                DispatchQueue.main.async { self?.refreshCamera() }
            }
            watchedCameras.insert(device)
        }
        refreshCamera()
    }

    func refreshCamera() {
        let cam = !suppressCamera && Self.anyCameraRunning()
        if cam != cameraInUse { cameraInUse = cam }
    }

    private func dedupe(_ apps: [AudioApp]) -> [AudioApp] {
        var seen = Set<String>()
        return apps.filter { seen.insert($0.id).inserted }
    }

    #if DEBUG
    func debugSet(camera: Bool, mic: Bool) {
        detailTimer?.invalidate()
        cameraFallback?.invalidate()
        cameraInUse = camera
        micInUse = mic
    }
    #endif

    // MARK: - Process → app

    private func resolve(_ proc: (pid: pid_t, bundleID: String)) -> AudioApp? {
        guard proc.pid != ownPID else { return nil }
        if let cached = appCache[proc.pid] { return cached }
        let app = Self.owningApp(pid: proc.pid, bundleID: proc.bundleID)
        appCache[proc.pid] = app
        if appCache.count > 300 { appCache.removeAll() }
        return app
    }

    /// Maps helper processes (Chrome/Electron renderers, WebKit) back to the app the user sees.
    private static func owningApp(pid: pid_t, bundleID: String) -> AudioApp? {
        if let running = NSRunningApplication(processIdentifier: pid) {
            if running.activationPolicy == .regular, let bid = running.bundleIdentifier {
                return AudioApp(id: bid, name: running.localizedName ?? bid, url: running.bundleURL)
            }
            if let path = (running.bundleURL ?? running.executableURL)?.path {
                let comps = URL(fileURLWithPath: path).pathComponents
                if let idx = comps.firstIndex(where: { $0.hasSuffix(".app") }) {
                    let appPath = NSString.path(withComponents: Array(comps[...idx]))
                    if let bid = Bundle(path: appPath)?.bundleIdentifier,
                       let owner = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                        .first(where: { $0.activationPolicy == .regular }) {
                        return AudioApp(id: bid, name: owner.localizedName ?? bid, url: owner.bundleURL)
                    }
                }
            }
        }
        if bundleID.hasPrefix("com.apple.WebKit"),
           let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first {
            return AudioApp(id: "com.apple.Safari", name: safari.localizedName ?? "Safari", url: safari.bundleURL)
        }
        return nil
    }

    // MARK: - CoreAudio

    @available(macOS 14.2, *)
    nonisolated private static func processActivity() -> (output: [(pid_t, String)], input: [(pid_t, String)]) {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else {
            return ([], [])
        }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return ([], [])
        }
        var out: [(pid_t, String)] = []
        var inp: [(pid_t, String)] = []
        for obj in ids {
            let runningOut = uint32(obj, kAudioProcessPropertyIsRunningOutput) == 1
            let runningIn = uint32(obj, kAudioProcessPropertyIsRunningInput) == 1
            guard runningOut || runningIn else { continue }
            var pid: pid_t = 0
            var psize = UInt32(MemoryLayout<pid_t>.size)
            var paddr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectGetPropertyData(obj, &paddr, 0, nil, &psize, &pid)
            let bid = string(obj, kAudioProcessPropertyBundleID) ?? ""
            if runningOut { out.append((pid, bid)) }
            if runningIn { inp.append((pid, bid)) }
        }
        return (out, inp)
    }

    nonisolated private static func uint32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 {
        var v: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : 0
    }

    nonisolated private static func string(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &ref) == noErr else { return nil }
        return ref?.takeRetainedValue() as String?
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID? {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = address(selector)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) == noErr, dev != 0 else { return nil }
        return dev
    }

    private static func isRunning(_ device: AudioDeviceID) -> Bool {
        uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0
    }

    // MARK: - CoreMediaIO

    private static func cameraDevices() -> [CMIOObjectID] {
        var addr = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                                             mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &addr, 0, nil, size, &used, &devices) == noErr else { return [] }
        return devices
    }

    private static func anyCameraRunning() -> Bool {
        for dev in cameraDevices() {
            var a = CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                                              mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                                              mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            var running: UInt32 = 0
            var got: UInt32 = 0
            if CMIOObjectGetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &got, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }
}
