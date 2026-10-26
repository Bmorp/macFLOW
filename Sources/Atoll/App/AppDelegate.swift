import AppKit
import SwiftUI
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var cancellables = Set<AnyCancellable>()
    private let statusItem = StatusItemController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()

        // Bring services up before the first hover so the island never waits.
        _ = NowPlayingModel.shared
        _ = SystemVolume.shared
        _ = BatteryMonitor.shared
        _ = CalendarModel.shared
        _ = ClipboardHistory.shared
        _ = ShelfModel.shared
        _ = AppCatalog.shared
        _ = AudioActivity.shared
        _ = SearchModel.shared
        _ = ActivityCenter.shared

        IslandManager.shared.start()
        WidgetManager.shared.start()
        StandByController.shared.start()
        DockBarController.shared.start()
        DockDropController.shared.start()
        DockTileController.shared.start()
        BrainEngine.shared.start()
        MorningPlanner.shared.start()
        FocusDimmer.shared.start()
        NewsStore.shared.start()
        AudioDevices.shared.start()
        DisplayControl.shared.start()
        Updater.shared.start()

        HotKeyCenter.shared.onTrigger = { IslandManager.shared.toggleSearch() }
        Prefs.shared.$hotKey
            .receive(on: RunLoop.main)
            .sink { HotKeyCenter.shared.register($0) }
            .store(in: &cancellables)

        Prefs.shared.$showMenuBarIcon
            .receive(on: RunLoop.main)
            .sink { [weak self] show in self?.statusItem.setVisible(show) }
            .store(in: &cancellables)

        refreshLoginItem()

        if !Prefs.shared.hasOnboarded {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { WindowManager.shared.showWelcome() }
        }
    }

    /// "Open at Login" remembers where the app was when it was turned on. Moved or renamed since (a new build, the copy
    /// in Applications), the login item points at nothing and the Mac logs in without Mac Flow — and without the
    /// morning planner. Re-register from where it is now; never turns it on if it was off.
    private func refreshLoginItem() {
        let here = Bundle.main.bundlePath
        let key = "loginItemPath"
        guard SMAppService.mainApp.status == .enabled, UserDefaults.standard.string(forKey: key) != here else { return }
        try? SMAppService.mainApp.unregister()
        if (try? SMAppService.mainApp.register()) != nil { UserDefaults.standard.set(here, forKey: key) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.showSettings()
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? { DockTileController.shared.menu() }

    /// `atoll://progress?…` from your scripts and builds — see CustomActivity.
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { CustomActivity.shared.handle($0) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        KeepAwake.shared.disable()
        HotKeyCenter.shared.unregister()
        Storage.flush()
    }
}
