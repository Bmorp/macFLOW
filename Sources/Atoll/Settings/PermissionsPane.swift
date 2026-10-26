import SwiftUI
import AppKit
import AVFoundation
import CoreBluetooth
import CoreLocation
import EventKit
import Speech

/// Every permission Mac Flow uses, what it's for, and whether it's on — live, so flipping a switch in System Settings
/// shows here straight away. "Ask" brings up macOS's own prompt for this exact build (which also fixes a switch that
/// looks on but belongs to an older build); "Open" goes straight to the right pane.
struct PermissionsPane: View {
    @State private var tick = 0
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    enum Status { case allowed, denied, notAsked, unknown }

    struct Item: Identifiable {
        let id: String
        let symbol: String
        let title: String
        let purpose: String
        let pane: String
        let status: () -> Status
        var ask: (() -> Void)?
    }

    private var items: [Item] {
        [
            Item(id: "ax", symbol: "accessibility", title: "Accessibility",
                 purpose: "Documents in rooms and Rewind, window titles at the Context level, keyboard shortcuts.",
                 pane: "Privacy_Accessibility",
                 status: { InputControl.isTrusted ? .allowed : .denied },
                 ask: { InputControl.requestTrust() }),
            Item(id: "cal", symbol: "calendar", title: "Calendars",
                 purpose: "Your next meeting, the day planner, moving events when you ask Flow.",
                 pane: "Privacy_Calendars",
                 status: {
                     switch EKEventStore.authorizationStatus(for: .event) {
                     case .fullAccess: .allowed
                     case .notDetermined: .notAsked
                     default: .denied
                     }
                 },
                 ask: { CalendarModel.shared.requestAccess() }),
            Item(id: "mic", symbol: "mic.fill", title: "Microphone",
                 purpose: "Hold the notch to talk; meeting notes you start (your side).",
                 pane: "Privacy_Microphone",
                 status: {
                     switch AVCaptureDevice.authorizationStatus(for: .audio) {
                     case .authorized: .allowed
                     case .notDetermined: .notAsked
                     default: .denied
                     }
                 },
                 ask: { AVCaptureDevice.requestAccess(for: .audio) { _ in } }),
            Item(id: "speech", symbol: "waveform", title: "Speech Recognition",
                 purpose: "Turning what you say into text — on this Mac only.",
                 pane: "Privacy_SpeechRecognition",
                 status: {
                     switch SFSpeechRecognizer.authorizationStatus() {
                     case .authorized: .allowed
                     case .notDetermined: .notAsked
                     default: .denied
                     }
                 },
                 ask: { SFSpeechRecognizer.requestAuthorization { _ in } }),
            Item(id: "audio", symbol: "speaker.wave.2.fill", title: "System Audio Recording",
                 purpose: "Hearing the other side of a call when you start meeting notes. Asked the first time you do.",
                 pane: "Privacy_ScreenCapture",
                 status: { .unknown }),
            Item(id: "bt", symbol: "dot.radiowaves.left.and.right", title: "Bluetooth",
                 purpose: "AirPods and headphones as they connect, with battery levels.",
                 pane: "Privacy_Bluetooth",
                 status: {
                     switch CBManager.authorization {
                     case .allowedAlways: .allowed
                     case .notDetermined: .notAsked
                     default: .denied
                     }
                 }),
            Item(id: "loc", symbol: "location.fill", title: "Location",
                 purpose: "Local weather in the notch (approximate).",
                 pane: "Privacy_LocationServices",
                 status: {
                     switch CLLocationManager().authorizationStatus {
                     case .authorizedAlways, .authorized: .allowed
                     case .notDetermined: .notAsked
                     default: .denied
                     }
                 }),
            Item(id: "auto", symbol: "gearshape.2.fill", title: "Automation",
                 purpose: "Controlling Music and Spotify — and playing a room's song.",
                 pane: "Privacy_Automation",
                 status: { .unknown }),
        ]
    }

    var body: some View {
        Form {
            Section {
                ForEach(items) { item in row(item) }
            } footer: {
                Text("Everything Mac Flow observes or hears stays on this Mac.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .id(tick)

            Section {
                Text("Builds of Mac Flow that aren’t signed look like a new app to macOS each time, so it forgets these switches after every update. A free signing certificate on this Mac fixes that:")
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Open Keychain Access, then choose Keychain Access › Certificate Assistant › Create a Certificate…")
                    Text("2. Name: Mac Flow Local · Identity Type: Self-Signed Root · Certificate Type: Code Signing")
                    Text("3. Click Create. The next build signs with it; grant permissions once more, and they stay.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                HStack {
                    Button("Open Keychain Access") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
                            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                    Spacer()
                    Text(Self.signedLocally ? "This build is signed with Mac Flow Local" : "This build isn’t signed")
                        .font(.caption)
                        .foregroundStyle(Self.signedLocally ? .green : .secondary)
                }
            } header: {
                Text("Keep Permissions Across Updates")
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in tick &+= 1 }
    }

    private func row(_ item: Item) -> some View {
        let status = item.status()
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color(status).gradient))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title)
                    Text(label(status)).font(.caption.weight(.semibold)).foregroundStyle(color(status))
                }
                Text(item.purpose).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if status != .allowed, let ask = item.ask {
                Button("Ask") { ask() }
            }
            Button("Open") { Self.open(item.pane) }
        }
        .padding(.vertical, 2)
    }

    private func label(_ s: Status) -> String {
        switch s {
        case .allowed: "Allowed"
        case .denied: "Off"
        case .notAsked: "Not asked yet"
        case .unknown: "Asked when needed"
        }
    }

    private func color(_ s: Status) -> Color {
        switch s {
        case .allowed: .green
        case .denied: .orange
        case .notAsked, .unknown: .gray
        }
    }

    /// Straight to the pane, in the current System Settings (and the older link as a fallback).
    static func open(_ pane: String) {
        let urls = ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)",
                    "x-apple.systempreferences:com.apple.preference.security?\(pane)"]
        for s in urls {
            if let url = URL(string: s), NSWorkspace.shared.open(url) { return }
        }
    }

    /// Whether this build carries the local signing certificate (so permissions survive updates).
    static let signedLocally: Bool = {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let certs = dict[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certs.first else { return false }
        return (SecCertificateCopySubjectSummary(leaf) as String?) == "Mac Flow Local"
    }()
}
