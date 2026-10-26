import SwiftUI
import AppKit

/// Live activities posted by your own tools — a build, a deploy, a long script — through `atoll://` links
/// or the bundled `atoll` command. Display only: a link can show text in the island, never run anything.
///
///     atoll://progress?title=Building&detail=Atoll&progress=24&symbol=hammer.fill&tint=blue
///     atoll://done?title=Build%20succeeded
///     atoll://fail?title=Tests%20failed
///     atoll://clear
@MainActor
final class CustomActivity: ObservableObject {
    static let shared = CustomActivity()

    enum State: Equatable { case running, done, failed }

    struct Item: Equatable {
        var title: String
        var detail: String?
        var symbol: String
        var tint: Color
        var progress: Double?
        var state: State
        var updated: Date
    }

    @Published private(set) var current: Item?

    init() {}
    /// Shown as a brief alert when an activity finishes.
    var onFinish: ((Item) -> Void)?
    private var expiry: DispatchWorkItem?

    func handle(_ url: URL) {
        guard ["atoll", "macflow"].contains(url.scheme?.lowercased() ?? "") else { return }
        let command = (url.host ?? url.path).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value.map(Self.clean) }

        switch command {
        case "diagnose":
            // Atoll's own state, written to its own folder — for checking a build without guessing.
            let np = NowPlayingModel.shared
            let report: [String: Any] = [
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                "music": ["title": np.title, "artist": np.artist, "album": np.album, "source": np.source?.name ?? "",
                          "playing": np.isPlaying, "mode": "\(np.mode)", "artwork": np.artwork.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "missing",
                          "field": np.palette == nil ? "missing" : "ready", "otherApp": np.otherApp?.name ?? "",
                          "scriptError": np.lastScriptError ?? "",
                          "automation": Dictionary(uniqueKeysWithValues: MediaSource.allCases.map { ($0.name, NowPlayingModel.automationAllowed($0).rawValue) })],
                "position": String(format: "%.1f / %.1f", np.position(), np.duration),
                "artwork": ["source": np.lastArt.source, "ms": np.lastArt.ms],
                "volume": ["atoll": String(format: "%.3f", SystemVolume.shared.volume), "muted": SystemVolume.shared.muted,
                           "available": SystemVolume.shared.available,
                           "output": AudioDevices.shared.currentOutput?.name ?? "?", "outputs": AudioDevices.shared.outputs.map(\.name)],
                "island": ["mode": "\(IslandManager.shared.primary?.model.mode ?? .compact)", "sticky": IslandManager.shared.primary?.model.sticky ?? false],
                "live": ActivityCenter.shared.live.map(\.rawValue),
                "flow": ["waiting": FlowInbox.shared.items.map { $0.key }, "planStarted": PlanStore.shared.plan.started,
                         "planItems": PlanStore.shared.plan.items.count, "morningDue": MorningPlanner.shared.isDue],
                "accessibility": InputControl.isTrusted,
                "audioApps": AudioActivity.shared.playing.map(\.id),
                "at": ISO8601DateFormatter().string(from: Date()),
            ]
            if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: Storage.directory.appendingPathComponent("diagnostics.json"))
            }
        case "plan":
            // Opens the day planner (nothing is changed until you press Start My Day).
            IslandManager.shared.openPlan()
        case "rewind", "day":
            // Rewind and your day: read-only views of today.
            IslandManager.shared.primary?.model.open(command == "day" ? .day : .rewind)
        case "progress", "start", "update":
            var item = current ?? Item(title: "Working", detail: nil, symbol: "hammer.fill", tint: DS.Palette.indigo,
                                       progress: nil, state: .running, updated: Date())
            if let t = value("title"), !t.isEmpty { item.title = t }
            if let d = value("detail") { item.detail = d.isEmpty ? nil : d }
            if let s = value("symbol"), NSImage(systemSymbolName: s, accessibilityDescription: nil) != nil { item.symbol = s }
            if let c = value("tint").flatMap(Self.color) { item.tint = c }
            if let p = value("progress").flatMap(Double.init) { item.progress = min(1, max(0, p > 1 ? p / 100 : p)) }
            item.state = .running
            item.updated = Date()
            withAnimation(Motion.morph) { current = item }
            scheduleExpiry(after: 15 * 60)
        case "done", "fail":
            let failed = command == "fail"
            var item = current ?? Item(title: "", detail: nil, symbol: "hammer.fill", tint: DS.Palette.indigo,
                                       progress: nil, state: .running, updated: Date())
            item.title = value("title") ?? (failed ? "Failed" : "Done")
            item.detail = value("detail")
            item.state = failed ? .failed : .done
            item.progress = failed ? item.progress : 1
            item.updated = Date()
            withAnimation(Motion.morph) { current = nil }
            onFinish?(item)
        case "clear":
            withAnimation(Motion.morph) { current = nil }
        default:
            break
        }
    }

    private func scheduleExpiry(after seconds: TimeInterval) {
        expiry?.cancel()
        let work = DispatchWorkItem { [weak self] in withAnimation(Motion.morph) { self?.current = nil } }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// One short line of plain text.
    nonisolated static func clean(_ s: String) -> String {
        let flat = s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        return String(String.UnicodeScalarView(flat)).trimmingCharacters(in: .whitespaces).prefix(64).description
    }

    static func color(_ name: String) -> Color? {
        switch name.lowercased() {
        case "blue": DS.Palette.blue
        case "green": DS.Palette.green
        case "orange": DS.Palette.orange
        case "red": DS.Palette.red
        case "yellow": DS.Palette.yellow
        case "purple", "indigo": DS.Palette.indigo
        case "cyan", "teal": DS.Palette.cyan
        case "pink": Color(red: 1, green: 0.22, blue: 0.48)
        default: Color(hex: name)
        }
    }

    #if DEBUG
    func debugSet(_ item: Item?) { current = item }
    #endif
}
