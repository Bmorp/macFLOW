import SwiftUI
import AppKit

/// What Mac Flow keeps, what it reads, and what it connects to — each with its switch.
struct PrivacyPane: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var history = ClipboardHistory.shared
    @ObservedObject private var notices = NoticeLog.shared
    @ObservedObject private var dev = DevStatus.shared

    var body: some View {
        Form {
            Section {
                Toggle("Keep Clipboard History", isOn: $prefs.clipboardEnabled)
                Toggle("Include Images", isOn: $prefs.clipboardImages).disabled(!prefs.clipboardEnabled)
                LabeledContent("Saved Items", value: "\(history.items.count)")
                Button("Clear Unpinned Items") { history.clearUnpinned() }.disabled(history.items.isEmpty)
            } header: {
                Text("Clipboard")
            } footer: {
                Text("Kept on this Mac only, and only while this is on. Passwords and anything an app marks as private or temporary are never kept.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                LabeledContent("Kept", value: "\(notices.notices.count) notifications")
                Button("Clear Notification History") { notices.clearAll() }.disabled(notices.notices.isEmpty)
            } header: {
                Text("Notifications")
            } footer: {
                Text("A history of what the island told you, so nothing is lost while it's busy or you're focusing. It lives in memory and is gone when Mac Flow quits.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Picker("Keep Flow's Memory For", selection: $prefs.brainRetentionDays) {
                    ForEach([7, 30, 90, 365], id: \.self) { Text("\($0) days").tag($0) }
                }
                LabeledContent("Language Model") {
                    Text(Mind.shared.isAvailable ? "Apple, on this Mac" : "Not available").foregroundStyle(.secondary)
                }
                if !Mind.shared.isAvailable {
                    Text(Mind.shared.unavailableReason).font(.caption).foregroundStyle(.secondary)
                }
                Button("Flow Settings…") { SettingsRouter.shared.page = .brain }
            } header: {
                Text("Flow")
            } footer: {
                Text("What Flow may see (apps, window titles, on-screen text) is chosen in Flow's settings. It runs on this Mac; nothing is sent anywhere.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                LabeledContent("GitHub") {
                    Text(githubStatus).foregroundStyle(.secondary)
                }
                ForEach(dev.repos) { r in
                    LabeledContent(r.name) {
                        Button("Stop Watching") { dev.forget(r.path) }
                    }
                }
                Button("Add Repository…") { DevStatus.shared.chooseRepository() }
            } header: {
                Text("Developer")
            } footer: {
                Text("Mac Flow reads Git status in the repositories listed here, the ports local processes listen on, and — through your own GitHub CLI login — reviews requested from you. It never writes to a repository.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onAppear { DevStatus.shared.refresh() }
    }

    private var githubStatus: String {
        switch dev.github {
        case .unknown: "Checking…"
        case .notInstalled: "GitHub CLI not installed"
        case .signedOut: "Signed out (run “gh auth login”)"
        case .ready: "Connected through the GitHub CLI"
        }
    }
}

/// The engine room: the island's renderer, how often things refresh, a report to share, and starting over.
struct AdvancedPane: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var engineOn = !(UserDefaults.standard.object(forKey: "legacyIsland") == nil ? true : UserDefaults.standard.bool(forKey: "legacyIsland"))
    @State private var engineChanged = false
    @State private var confirmReset = false
    @State private var copied = false

    var body: some View {
        Form {
            Section {
                Toggle("Core Animation Island", isOn: Binding(get: { engineOn }, set: { on in
                    engineOn = on
                    UserDefaults.standard.set(!on, forKey: "legacyIsland")
                    engineChanged = true
                }))
                if engineChanged {
                    HStack {
                        Text("Takes effect when Mac Flow restarts.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Now") { AppRestart.now() }
                    }
                }
            } header: {
                Text("Island Engine")
            } footer: {
                Text("Draws the island's shape and springs in Core Animation, so it stays smooth while the app is busy, and lets gestures follow your fingers. Turn it off to use the original renderer.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Picker("System Monitor Refresh", selection: $prefs.statsInterval) {
                    Text("Every second").tag(1.0)
                    Text("Every 2 seconds").tag(2.0)
                    Text("Every 5 seconds").tag(5.0)
                }
            } header: {
                Text("Refresh")
            } footer: {
                Text("Readings are taken only while something on screen shows them.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                ForEach(Diagnostics.lines(), id: \.0) { line in
                    LabeledContent(line.0) { Text(line.1).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                Button(copied ? "Copied" : "Copy Diagnostics") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Diagnostics.report(), forType: .string)
                    copied = true
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("A plain-text summary to paste into an issue on GitHub. It has no personal data: no file names, no clipboard, nothing Flow knows.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Button("Reset All Settings…", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Every setting goes back to how it was on day one. Your tasks, clipboard history and what Flow learned are kept.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all of Mac Flow's settings?", isPresented: $confirmReset) {
            Button("Reset and Restart", role: .destructive) { Diagnostics.resetSettings(); AppRestart.now() }
        } message: {
            Text("Mac Flow restarts with its original settings.")
        }
    }
}

/// Quits and opens this copy of the app again.
@MainActor
enum AppRestart {
    static func now() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.7; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

@MainActor
enum Diagnostics {
    static func lines() -> [(String, String)] {
        let info = Bundle.main.infoDictionary
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let screens = NSScreen.screens.map { s -> String in
            let notch = NotchGeometry.detect(for: s)
            return "\(Int(s.frame.width))×\(Int(s.frame.height))\(notch.hasNotch ? " notch \(Int(notch.notchSize.width))" : "")"
        }.joined(separator: ", ")
        var usage = rusage_info_current()
        let rss: String = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: Optional<rusage_info_t>.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_CURRENT, $0) == 0 ? "\(ptr.pointee.ri_phys_footprint / 1_048_576) MB" : "—"
            }
        }
        return [
            ("Version", "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"),
            ("macOS", "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
            ("Displays", screens),
            ("Island", (UserDefaults.standard.object(forKey: "legacyIsland") as? Bool ?? true) ? "Original renderer" : "Core Animation engine"),
            ("Haptics", TrackpadActuator.shared.available ? "Trackpad motor" : "Standard (app must be in front)"),
            ("Memory", rss),
            ("Accessibility", InputControl.isTrusted ? "Allowed" : "Not allowed"),
        ]
    }

    static func report() -> String {
        (["Mac Flow diagnostics"] + lines().map { "\($0.0): \($0.1)" }).joined(separator: "\n")
    }

    /// Every preference back to its default, keeping only that onboarding has happened.
    static func resetSettings() {
        guard let domain = Bundle.main.bundleIdentifier else { return }
        let onboarded = UserDefaults.standard.bool(forKey: "hasOnboarded5")
        UserDefaults.standard.removePersistentDomain(forName: domain)
        UserDefaults.standard.set(onboarded, forKey: "hasOnboarded5")
    }
}
