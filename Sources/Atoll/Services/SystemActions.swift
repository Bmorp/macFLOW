import AppKit
import SwiftUI
import IOKit.pwr_mgt

/// Prevents display sleep while on — a native caffeinate toggle.
@MainActor
final class KeepAwake: ObservableObject {
    static let shared = KeepAwake()

    @Published private(set) var isOn = false
    @Published private(set) var since: Date?
    private var assertion = IOPMAssertionID(0)

    func toggle() { isOn ? disable() : enable() }

    func enable() {
        guard !isOn else { return }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName("PreventUserIdleDisplaySleep" as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Mac Flow Keep Awake" as CFString, &id)
        if result == kIOReturnSuccess {
            assertion = id
            since = Date()
            isOn = true
        }
    }

    #if DEBUG
    func debugSet(_ on: Bool) {
        isOn = on
        since = on ? Date().addingTimeInterval(-47 * 60) : nil
    }
    #endif

    func disable() {
        guard isOn else { return }
        IOPMAssertionRelease(assertion)
        since = nil
        isOn = false
    }
}

/// NSAppleScript isn't thread-safe: every script Atoll runs (players, appearance) goes through this one serial queue.
let appleScriptQueue = DispatchQueue(label: "atoll.applescript", qos: .userInitiated)

@MainActor
enum SystemActions {
    private static var sampler: NSColorSampler?

    static func lockScreen() {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let handle = dlopen(path, RTLD_LAZY), let sym = dlsym(handle, "SACLockScreenImmediate") {
            typealias LockFn = @convention(c) () -> Int32
            _ = unsafeBitCast(sym, to: LockFn.self)()
        } else {
            sleepDisplays()
        }
    }

    static func sleepDisplays() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }

    static func toggleDarkMode() {
        let source = "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
        appleScriptQueue.async {
            var err: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&err)
        }
    }

    static func screenshot() {
        let url = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    static func pickColor(_ done: @escaping (String) -> Void) {
        let s = NSColorSampler()
        sampler = s
        s.show { color in
            MainActor.assumeIsolated { sampler = nil }
            guard let c = color?.usingColorSpace(.sRGB) else { return }
            let hex = String(format: "#%02X%02X%02X",
                             Int((c.redComponent * 255).rounded()),
                             Int((c.greenComponent * 255).rounded()),
                             Int((c.blueComponent * 255).rounded()))
            MainActor.assumeIsolated {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(hex, forType: .string)
                done(hex)
            }
        }
    }

    static func openURL(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }

    static func webSearch(_ query: String) {
        var comps = URLComponents(string: "https://www.google.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: query)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }
}

/// Searchable command palette entries.
enum SystemCommand: String, CaseIterable, Identifiable {
    case lockScreen, sleepDisplays, toggleDarkMode, keepAwake, colorPicker, screenshot, mirror
    case focus25, focus5, clearClipboard, showShelf, settings, quit

    var id: String { rawValue }

    @MainActor var title: String {
        switch self {
        case .lockScreen: "Lock Screen"
        case .sleepDisplays: "Sleep Displays"
        case .toggleDarkMode: "Toggle Dark Mode"
        case .keepAwake: KeepAwake.shared.isOn ? "Allow Mac to Sleep" : "Keep Mac Awake"
        case .colorPicker: "Pick a Color"
        case .screenshot: "Take Screenshot"
        case .mirror: "Mirror"
        case .focus25: "Start 25-Minute Focus Timer"
        case .focus5: "Start 5-Minute Break"
        case .clearClipboard: "Clear Clipboard History"
        case .showShelf: "Show Shelf"
        case .settings: "Mac Flow Settings…"
        case .quit: "Quit Mac Flow"
        }
    }

    var symbol: String {
        switch self {
        case .lockScreen: "lock.fill"
        case .sleepDisplays: "moon.zzz.fill"
        case .toggleDarkMode: "circle.lefthalf.filled"
        case .keepAwake: "cup.and.saucer.fill"
        case .colorPicker: "eyedropper.halffull"
        case .screenshot: "camera.viewfinder"
        case .mirror: "person.crop.square.fill"
        case .focus25: "timer"
        case .focus5: "leaf.fill"
        case .clearClipboard: "clipboard"
        case .showShelf: "tray.full.fill"
        case .settings: "gearshape.fill"
        case .quit: "power"
        }
    }

    var keywords: [String] {
        switch self {
        case .lockScreen: ["lock", "away", "secure"]
        case .sleepDisplays: ["sleep", "display", "screen off"]
        case .toggleDarkMode: ["dark", "light", "appearance", "theme", "mode"]
        case .keepAwake: ["awake", "caffeine", "caffeinate", "amphetamine", "coffee", "sleep"]
        case .colorPicker: ["color", "colour", "picker", "eyedropper", "hex"]
        case .screenshot: ["screenshot", "capture", "screen", "record"]
        case .mirror: ["mirror", "camera", "webcam", "selfie", "face", "hair"]
        case .focus25: ["focus", "pomodoro", "timer", "work"]
        case .focus5: ["break", "rest", "timer"]
        case .clearClipboard: ["clipboard", "clear", "history"]
        case .showShelf: ["shelf", "files", "tray", "airdrop"]
        case .settings: ["settings", "preferences", "config", "atoll"]
        case .quit: ["quit", "exit", "close atoll"]
        }
    }

    @MainActor func matches(_ q: String) -> Bool {
        let q = q.lowercased()
        return title.lowercased().contains(q) || keywords.contains { $0.hasPrefix(q) || q.hasPrefix($0) }
    }
}
