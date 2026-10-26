import AppKit

/// Accessory apps have no visible menu bar, but text fields still rely on the Edit menu's
/// key equivalents (⌘C ⌘V ⌘A ⌘Z), and ⌘, / ⌘Q should behave as everywhere else.
@MainActor
enum MainMenu {
    static func install() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let app = NSMenu()
        app.addItem(item("About Mac Flow", #selector(AppActions.about)))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(AppActions.settings), key: ","))
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Mac Flow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = app
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z").keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    static func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = AppActions.shared
        return i
    }
}

/// Every command, reachable from a menu.
@MainActor
final class AppActions: NSObject {
    static let shared = AppActions()

    @objc func about() { WindowManager.shared.showAbout() }
    @objc func settings() { WindowManager.shared.showSettings() }
    @objc func search() { IslandManager.shared.openSearch() }
    @objc func clipboard() { IslandManager.shared.openSearch(scope: .clipboard) }
    @objc func shelf() { IslandManager.shared.openShelf() }
    @objc func mirror() { IslandManager.shared.openMirror() }
    @objc func toggleAwake() { KeepAwake.shared.toggle() }
    @objc func stopTimer() { FocusTimer.shared.stop() }
    @objc func editWidgets() { WidgetManager.shared.beginEditing() }
    @objc func standBy() { StandByController.shared.enter(manual: true) }
    @objc func dockCompanion() { DockBarController.shared.show() }
    @objc func startTimer(_ sender: NSMenuItem) {
        FocusTimer.shared.start(minutes: sender.tag, label: sender.tag <= 10 ? "Break" : "Focus")
    }
}
