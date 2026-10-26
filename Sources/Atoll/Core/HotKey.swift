import Carbon.HIToolbox
import Foundation

/// System-wide shortcuts via Carbon hot keys (no Accessibility permission required).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    /// The configurable search shortcut.
    var onTrigger: (() -> Void)?
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?

    private static let searchID: UInt32 = 1

    func register(_ choice: HotKeyChoice) {
        unregister(id: Self.searchID)
        guard choice != .disabled else { return }
        add(id: Self.searchID, keyCode: choice.keyCode, modifiers: choice.modifiers) { [weak self] in self?.onTrigger?() }
    }

    /// Registers a fixed shortcut under its own id.
    func add(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        unregister(id: id)
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x41544F4C), id: id) // 'ATOL'
        if RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
            refs[id] = ref
            actions[id] = action
        }
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions[id] = nil
    }

    func unregister() {
        for id in Array(refs.keys) { unregister(id: id) }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeyCenter.shared.actions[id]?() }
            return noErr
        }, 1, &spec, nil, &handlerRef)
    }
}
