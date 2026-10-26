import AppKit
import SwiftUI

@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var settingsWindow: NSWindow?
    private var welcomeWindow: NSWindow?

    func showSettings(page: SettingsPage? = nil) {
        if settingsWindow == nil { settingsWindow = SettingsWindow.make() }
        if let page { SettingsRouter.shared.page = page }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showAbout() { showSettings(page: .about) }

    func showWelcome() {
        if welcomeWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: WelcomeView { [weak self] in
                Prefs.shared.hasOnboarded = true
                self?.welcomeWindow?.close()
                // Teach through use: the island introduces itself right where it lives.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { IslandManager.shared.startTour() }
            })
            host.sizingOptions = []
            w.contentViewController = host
            w.setContentSize(NSSize(width: 500, height: 600))
            w.center()
            welcomeWindow = w
        }
        NSApp.activate()
        welcomeWindow?.makeKeyAndOrderFront(nil)
    }
}
