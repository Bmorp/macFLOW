import AppKit

/// The user's Shortcuts (via the built-in `shortcuts` CLI) and System Settings panes, searchable from the launcher.
@MainActor
final class ShortcutsService: ObservableObject {
    static let shared = ShortcutsService()

    @Published private(set) var names: [String] = []
    private var lastLoad = Date.distantPast

    #if DEBUG
    func debugSet(_ list: [String]) {
        names = list
        lastLoad = Date()
    }
    #endif

    func refreshIfStale() {
        guard Date().timeIntervalSince(lastLoad) > 300 else { return }
        lastLoad = Date()
        Task.detached(priority: .utility) {
            let list = ShortcutsService.runCLI(["list"]) ?? ""
            let names = list.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            await MainActor.run { ShortcutsService.shared.names = names }
        }
    }

    func search(_ q: String, limit: Int = 3) -> [String] {
        let lower = q.lowercased()
        return names.filter { $0.lowercased().contains(lower) }
            .sorted { a, b in a.lowercased().hasPrefix(lower) && !b.lowercased().hasPrefix(lower) }
            .prefix(limit).map { $0 }
    }

    func run(_ name: String) {
        Task.detached(priority: .userInitiated) {
            _ = ShortcutsService.runCLI(["run", name])
        }
    }

    func openEditor(_ name: String) {
        var comps = URLComponents()
        comps.scheme = "shortcuts"
        comps.host = "open-shortcut"
        comps.queryItems = [URLQueryItem(name: "name", value: name)]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    nonisolated private static func runCLI(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}

struct SettingsPane: Identifiable, Equatable {
    let id: String
    let title: String
    let symbol: String
    let keywords: [String]

    var url: URL? { URL(string: "x-apple.systempreferences:\(id)") }

    func open() { if let url { NSWorkspace.shared.open(url) } }

    static let all: [SettingsPane] = [
        .init(id: "com.apple.wifi-settings-extension", title: "Wi‑Fi", symbol: "wifi", keywords: ["wifi", "wi-fi", "wireless", "internet"]),
        .init(id: "com.apple.BluetoothSettings", title: "Bluetooth", symbol: "dot.radiowaves.left.and.right", keywords: ["bluetooth", "airpods", "pair"]),
        .init(id: "com.apple.Network-Settings.extension", title: "Network", symbol: "network", keywords: ["network", "vpn", "ethernet", "dns"]),
        .init(id: "com.apple.Displays-Settings.extension", title: "Displays", symbol: "display", keywords: ["display", "resolution", "monitor", "night shift", "brightness"]),
        .init(id: "com.apple.Sound-Settings.extension", title: "Sound", symbol: "speaker.wave.2.fill", keywords: ["sound", "audio", "output", "input", "microphone", "volume"]),
        .init(id: "com.apple.Battery-Settings.extension", title: "Battery", symbol: "battery.100percent", keywords: ["battery", "power", "energy", "low power"]),
        .init(id: "com.apple.Focus-Settings.extension", title: "Focus", symbol: "moon.fill", keywords: ["focus", "do not disturb", "dnd"]),
        .init(id: "com.apple.Notifications-Settings.extension", title: "Notifications", symbol: "bell.badge.fill", keywords: ["notifications", "alerts", "banners"]),
        .init(id: "com.apple.Appearance-Settings.extension", title: "Appearance", symbol: "circle.lefthalf.filled", keywords: ["appearance", "dark", "light", "accent"]),
        .init(id: "com.apple.Desktop-Settings.extension", title: "Desktop & Dock", symbol: "dock.rectangle", keywords: ["dock", "desktop", "stage manager", "mission control", "hot corners"]),
        .init(id: "com.apple.Wallpaper-Settings.extension", title: "Wallpaper", symbol: "photo.on.rectangle", keywords: ["wallpaper", "background"]),
        .init(id: "com.apple.Keyboard-Settings.extension", title: "Keyboard", symbol: "keyboard", keywords: ["keyboard", "shortcuts", "input sources", "dictation"]),
        .init(id: "com.apple.Trackpad-Settings.extension", title: "Trackpad", symbol: "rectangle.and.hand.point.up.left.filled", keywords: ["trackpad", "gestures", "force click", "haptic"]),
        .init(id: "com.apple.settings.PrivacySecurity.extension", title: "Privacy & Security", symbol: "hand.raised.fill", keywords: ["privacy", "security", "permissions", "filevault"]),
        .init(id: "com.apple.LoginItems-Settings.extension", title: "Login Items", symbol: "person.badge.key.fill", keywords: ["login items", "startup", "background"]),
        .init(id: "com.apple.Software-Update-Settings.extension", title: "Software Update", symbol: "arrow.triangle.2.circlepath", keywords: ["update", "software update", "macos"]),
        .init(id: "com.apple.Accessibility-Settings.extension", title: "Accessibility", symbol: "accessibility", keywords: ["accessibility", "zoom", "voiceover"]),
        .init(id: "com.apple.Storage-Settings.extension", title: "Storage", symbol: "internaldrive.fill", keywords: ["storage", "disk", "space"]),
    ]

    static func search(_ q: String) -> [SettingsPane] {
        let lower = q.lowercased()
        guard lower.count >= 3 else { return [] }
        return all.filter { p in
            p.title.lowercased().hasPrefix(lower) || p.keywords.contains { $0.hasPrefix(lower) }
        }.prefix(2).map { $0 }
    }
}
