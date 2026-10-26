import AppKit
import ScreenCaptureKit
import Vision

/// The "Everything" tier: reads the text in the window you're using — on this Mac, with Apple's Vision — and keeps
/// only a short, condensed version for the Brain. At most once a minute, only when the window changed, never for
/// excluded apps, password managers or private windows.
@MainActor
final class ScreenSensor {
    static let shared = ScreenSensor()

    /// The latest condensed reading of the focused window.
    private(set) var latest: (app: String, text: String, at: Date)?
    private var timer: Timer?
    private var lastKey = ""
    private var lastRead = Date.distantPast
    private var reading = false

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let ctx = WorkContext.shared
        guard ctx.level == .everything, !ctx.isIdle, CGPreflightScreenCaptureAccess(), !reading,
              !Prefs.shared.brainExcluded.contains(ctx.bundle), !Understanding.isPrivate(bundle: ctx.bundle, title: ctx.title),
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == ctx.bundle,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        if let until = Prefs.shared.brainPausedUntil, until > Date() { return }
        let key = "\(ctx.bundle)|\(ctx.title)"
        // A new window right away; the same window at most every two minutes.
        guard key != lastKey || Date().timeIntervalSince(lastRead) > 120, Date().timeIntervalSince(lastRead) > 60 else { return }
        guard let windowID = Self.frontWindowID(pid: app.processIdentifier) else { return }
        reading = true
        lastKey = key
        lastRead = Date()
        let appName = ctx.appName
        let bundle = ctx.bundle
        Task {
            let text = await Self.read(windowID: windowID)
            await MainActor.run {
                let me = ScreenSensor.shared
                me.reading = false
                guard let text, !text.isEmpty else { return }
                me.latest = (appName, text, Date())
                BrainStore.shared.record(.init(ts: Date(), kind: "screen", app: appName, bundle: bundle, title: WorkContext.shared.title, detail: text))
            }
        }
    }

    /// The frontmost normal window of an app.
    private static func frontWindowID(pid: pid_t) -> CGWindowID? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            if let id = w[kCGWindowNumber as String] as? CGWindowID { return id }
        }
        return nil
    }

    nonisolated private static func read(windowID: CGWindowID) async -> String? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale: CGFloat = 1.5
        config.width = Int(window.frame.width * scale)
        config.height = Int(window.frame.height * scale)
        config.showsCursor = false
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        return condense(recognize(image))
    }

    nonisolated private static func recognize(_ image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image)
        try? handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// Keeps what carries meaning: distinct, wordy lines, at most ~500 characters.
    nonisolated static func condense(_ lines: [String]) -> String {
        var seen = Set<String>()
        var out: [String] = []
        var total = 0
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let words = line.split(separator: " ").count
            guard words >= 3, line.count >= 12, seen.insert(line.lowercased()).inserted else { continue }
            // Skip things that look like secrets or numbers-only noise.
            if line.range(of: #"\b[A-Za-z0-9_\-]{28,}\b"#, options: .regularExpression) != nil { continue }
            out.append(line)
            total += line.count
            if total > 500 { break }
        }
        return out.joined(separator: " · ")
    }
}
