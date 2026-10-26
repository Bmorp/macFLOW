import CoreAudio
import AudioToolbox
import Foundation

/// System output volume via CoreAudio — no permissions, follows device switches live.
@MainActor
final class SystemVolume: ObservableObject {
    static let shared = SystemVolume()

    @Published private(set) var volume: Double = 0.5
    @Published private(set) var muted = false
    @Published private(set) var available = true

    private var device = AudioDeviceID(0)
    private var listenedDevice = AudioDeviceID(0)
    private lazy var changeBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        DispatchQueue.main.async { self?.read() }
    }

    init() {
        device = Self.defaultOutputDevice()
        read()
        var sysAddr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &sysAddr, DispatchQueue.main) { [weak self] _, _ in
            DispatchQueue.main.async { self?.deviceChanged() }
        }
        attachDeviceListeners()
    }

    private static func defaultOutputDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    private func addr(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private func deviceChanged() {
        detachDeviceListeners()
        device = Self.defaultOutputDevice()
        attachDeviceListeners()
        read()
    }

    private func attachDeviceListeners() {
        var v = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var m = addr(kAudioDevicePropertyMute)
        AudioObjectAddPropertyListenerBlock(device, &v, DispatchQueue.main, changeBlock)
        AudioObjectAddPropertyListenerBlock(device, &m, DispatchQueue.main, changeBlock)
        listenedDevice = device
    }

    private func detachDeviceListeners() {
        var v = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        var m = addr(kAudioDevicePropertyMute)
        AudioObjectRemovePropertyListenerBlock(listenedDevice, &v, DispatchQueue.main, changeBlock)
        AudioObjectRemovePropertyListenerBlock(listenedDevice, &m, DispatchQueue.main, changeBlock)
    }

    func read() {
        var v = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        // Assign only real changes: each publish re-renders the player and re-triggers the volume alert.
        if AudioObjectGetPropertyData(device, &a, 0, nil, &size, &v) == noErr {
            if !available { available = true }
            if abs(Double(v) - volume) > 0.001 { volume = Double(v) }
        } else if available {
            available = false
        }
        var m = UInt32(0)
        size = UInt32(MemoryLayout<UInt32>.size)
        var ma = addr(kAudioDevicePropertyMute)
        if AudioObjectGetPropertyData(device, &ma, 0, nil, &size, &m) == noErr, muted != (m != 0) {
            muted = m != 0
        }
    }

    func set(_ value: Double) {
        var v = Float32(min(max(value, 0), 1))
        var a = addr(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        volume = Double(v)
        if muted && v > 0 { setMuted(false) }
    }

    func setMuted(_ on: Bool) {
        var m = UInt32(on ? 1 : 0)
        var a = addr(kAudioDevicePropertyMute)
        AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &m)
        muted = on
    }

    var symbol: String {
        if muted || volume < 0.01 { return "speaker.slash.fill" }
        if volume < 0.34 { return "speaker.wave.1.fill" }
        if volume < 0.67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
