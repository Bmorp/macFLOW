import AppKit
import CoreAudio

/// Every audio output and input on this Mac, which one is in use, and switching between them —
/// AirPods, speakers, displays, USB interfaces. Also the microphone's mute.
@MainActor
final class AudioDevices: ObservableObject {
    static let shared = AudioDevices()

    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
        let transport: UInt32

        var symbol: String {
            let n = name.lowercased()
            if n.contains("airpods max") { return "airpodsmax" }
            if n.contains("airpods pro") { return "airpodspro" }
            if n.contains("airpods") { return "airpods" }
            if n.contains("beats") { return "beats.headphones" }
            if n.contains("homepod") { return "homepod.fill" }
            switch transport {
            case kAudioDeviceTransportTypeBuiltIn: return n.contains("microphone") ? "mic.fill" : "laptopcomputer"
            case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
            case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return "tv"
            case kAudioDeviceTransportTypeAirPlay: return "airplayaudio"
            case kAudioDeviceTransportTypeUSB: return "hifispeaker.fill"
            case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "square.stack.3d.down.right.fill"
            default: return "speaker.wave.2.fill"
            }
        }
    }

    @Published private(set) var outputs: [Device] = []
    @Published private(set) var inputs: [Device] = []
    @Published private(set) var output: AudioDeviceID = 0
    @Published private(set) var input: AudioDeviceID = 0
    @Published private(set) var inputMuted = false

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        reload()
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice] {
            var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(system, &a, DispatchQueue.main) { _, _ in
                MainActor.assumeIsolated { AudioDevices.shared.reload() }
            }
        }
    }

    var currentOutput: Device? { outputs.first { $0.id == output } }
    var currentInput: Device? { inputs.first { $0.id == input } }

    func reload() {
        let all = Self.deviceIDs()
        let outs = all.filter { Self.channels($0, kAudioObjectPropertyScopeOutput) > 0 }.compactMap { Self.device($0) }
        let ins = all.filter { Self.channels($0, kAudioObjectPropertyScopeInput) > 0 }.compactMap { Self.device($0) }
        if outs != outputs { outputs = outs }
        if ins != inputs { inputs = ins }
        output = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        input = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        inputMuted = Self.muted(input)
    }

    func useOutput(_ d: Device) { Self.setDefault(kAudioHardwarePropertyDefaultOutputDevice, d.id); Self.setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, d.id); reload() }
    func useInput(_ d: Device) { Self.setDefault(kAudioHardwarePropertyDefaultInputDevice, d.id); reload() }

    func setInputMuted(_ on: Bool) {
        var m = UInt32(on ? 1 : 0)
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectSetPropertyData(input, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m) != noErr {
            // No hardware mute: silence the input level instead.
            var v = Float32(on ? 0 : 0.75)
            var va = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            AudioObjectSetPropertyData(input, &va, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
        inputMuted = on
    }

    // MARK: CoreAudio

    private static func deviceIDs() -> [AudioDeviceID] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func channels(_ id: AudioDeviceID, _ scope: AudioObjectPropertyScope) -> Int {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func device(_ id: AudioDeviceID) -> Device? {
        var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name) == noErr, let n = name?.takeRetainedValue() as String? else { return nil }
        // Hide plumbing devices nobody chooses on purpose.
        if n.hasPrefix("CADefaultDevice") || n.contains("Microsoft Teams Audio") || n.contains("ZoomAudioDevice") { return nil }
        var t = UInt32(0)
        var ta = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &ta, 0, nil, &size, &t)
        return Device(id: id, name: n, transport: t)
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &id)
        return id
    }

    private static func setDefault(_ selector: AudioObjectPropertySelector, _ id: AudioDeviceID) {
        var dev = id
        var a = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &dev)
    }

    private static func muted(_ id: AudioDeviceID) -> Bool {
        var m = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(id, &a, 0, nil, &size, &m) == noErr { return m != 0 }
        var v = Float32(1)
        size = UInt32(MemoryLayout<Float32>.size)
        var va = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(id, &va, 0, nil, &size, &v) == noErr { return v < 0.01 }
        return false
    }
}
