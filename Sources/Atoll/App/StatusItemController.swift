import AppKit

/// Menu bar extra: every island command in one standard menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private var item: NSStatusItem?

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let i = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            i.button?.image = Brand.menuBarImage()
            i.button?.setAccessibilityLabel("Mac Flow")
            let menu = NSMenu()
            menu.delegate = self
            i.menu = menu
            item = i
        } else if !visible, let i = item {
            NSStatusBar.system.removeStatusItem(i)
            item = nil
        }
    }

    /// A small island resting on a reef — the app icon, reduced to a template glyph.
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild(menu) }
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let hk = Prefs.shared.hotKey

        let search = MainMenu.item("Search…", #selector(AppActions.search))
        if hk != .disabled { search.title = "Search…\t\(hk.label)" }
        menu.addItem(search)
        menu.addItem(MainMenu.item("Clipboard History…", #selector(AppActions.clipboard)))
        let shelf = MainMenu.item("Show Shelf", #selector(AppActions.shelf))
        shelf.isEnabled = !ShelfModel.shared.items.isEmpty
        menu.addItem(shelf)
        menu.addItem(.separator())

        if FocusTimer.shared.isActive {
            menu.addItem(MainMenu.item("Stop Timer (\(FocusTimer.shared.clock))", #selector(AppActions.stopTimer)))
        } else {
            let timer = NSMenuItem(title: "Start Timer", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for m in [5, 10, 15, 25, 50] {
                let i = MainMenu.item("\(m) Minutes", #selector(AppActions.startTimer(_:)))
                i.tag = m
                sub.addItem(i)
            }
            timer.submenu = sub
            menu.addItem(timer)
        }
        let awake = MainMenu.item("Keep Mac Awake", #selector(AppActions.toggleAwake))
        awake.state = KeepAwake.shared.isOn ? .on : .off
        menu.addItem(awake)
        menu.addItem(MainMenu.item("Mirror", #selector(AppActions.mirror)))
        menu.addItem(.separator())
        menu.addItem(MainMenu.item("Edit Widgets…", #selector(AppActions.editWidgets)))
        menu.addItem(MainMenu.item("Enter StandBy\t⌃⌘S", #selector(AppActions.standBy)))
        if Prefs.shared.dockCompanion {
            menu.addItem(MainMenu.item("Show Dock Companion", #selector(AppActions.dockCompanion)))
        }
        menu.addItem(.separator())
        menu.addItem(MainMenu.item("Settings…", #selector(AppActions.settings), key: ","))
        menu.addItem(MainMenu.item("About Mac Flow", #selector(AppActions.about)))
        if let release = Updater.shared.available {
            menu.addItem(MainMenu.item("Update to Mac Flow \(release.version)…", #selector(AppActions.installUpdate)))
        } else {
            menu.addItem(MainMenu.item("Check for Updates…", #selector(AppActions.checkForUpdates)))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Mac Flow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }
}
