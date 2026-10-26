import AppKit

/// Flow and your browser: what page you're on (title and address, from Chrome, Arc, Brave, Edge or Safari), and — if you
/// allow JavaScript from Apple Events in that browser — the page's words, so Flow can summarize it, explain it, answer
/// questions about it, or turn it into cards to learn from. Read on demand only, processed on this Mac.
enum BrowserReader {
    struct Browser: Equatable {
        let bundle: String
        let name: String
        /// AppleScript for the front tab, in this browser's dialect.
        let tab: String
        let usesSafariDialect: Bool
    }

    static let browsers: [Browser] = [
        Browser(bundle: "com.google.Chrome", name: "Chrome", tab: "active tab of front window", usesSafariDialect: false),
        Browser(bundle: "company.thebrowser.Browser", name: "Arc", tab: "active tab of front window", usesSafariDialect: false),
        Browser(bundle: "com.brave.Browser", name: "Brave", tab: "active tab of front window", usesSafariDialect: false),
        Browser(bundle: "com.microsoft.edgemac", name: "Edge", tab: "active tab of front window", usesSafariDialect: false),
        Browser(bundle: "com.apple.Safari", name: "Safari", tab: "current tab of front window", usesSafariDialect: true),
    ]

    static func browser(for bundle: String?) -> Browser? { browsers.first { $0.bundle == bundle } }

    struct Page: Equatable {
        let browser: String
        let title: String
        let url: URL
    }

    enum Text: Equatable {
        case text(String)
        /// The browser said no: JavaScript from Apple Events is off (how to turn it on is in `howToAllow`).
        case notAllowed(String)
        /// macOS said no: Mac Flow isn't allowed to control this browser (Privacy & Security › Automation).
        case notPermitted(String)
        case unavailable
    }

    private static let queue = DispatchQueue(label: "atoll.browser", qos: .userInitiated)

    /// The page in the front browser window.
    static func page(in b: Browser, completion: @escaping @Sendable (Page?) -> Void) {
        let urlKey = b.usesSafariDialect ? "URL" : "URL"
        let titleKey = b.usesSafariDialect ? "name" : "title"
        let script = """
        tell application id "\(b.bundle)"
            if (count of windows) is 0 then return ""
            set t to \(b.tab)
            return (\(urlKey) of t) & linefeed & (\(titleKey) of t)
        end tell
        """
        queue.async {
            let parts = Script.run(script)?.components(separatedBy: "\n") ?? []
            guard parts.count >= 2, let url = URL(string: parts[0]), ["http", "https"].contains(url.scheme ?? "") else { completion(nil); return }
            completion(Page(browser: b.name, title: parts[1...].joined(separator: " "), url: url))
        }
    }

    /// The page's words (up to ~12,000 characters).
    static func text(in b: Browser, completion: @escaping @Sendable (Text) -> Void) {
        let js = "document.body ? document.body.innerText.slice(0, 12000) : ''"
        let script = b.usesSafariDialect
            ? "tell application id \"\(b.bundle)\" to do JavaScript \"\(js)\" in \(b.tab)"
            : "tell application id \"\(b.bundle)\" to execute \(b.tab) javascript \"\(js)\""
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&error)
            if let error {
                let message = (error[NSAppleScript.errorMessage] as? String ?? "").lowercased()
                let number = (error[NSAppleScript.errorNumber] as? Int) ?? 0
                if number == -1743 || number == -10004 || message.contains("not authorized") {
                    completion(.notPermitted(b.name))
                } else {
                    completion(message.contains("javascript") || message.contains("allow") ? .notAllowed(b.name) : .unavailable)
                }
                return
            }
            let text = result?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            completion(text.count >= 40 ? .text(text) : .unavailable)
        }
    }

    static func howToAllow(_ browser: String) -> String {
        browser == "Safari"
            ? "In Safari, turn on Develop › Allow JavaScript from Apple Events (Settings › Advanced › Show features for web developers)."
            : "In \(browser), turn on View › Developer › Allow JavaScript from Apple Events."
    }
}

/// What Flow can do with the page you're reading.
enum PageAction: String, CaseIterable {
    case summarize, explain, learn, ask

    var title: String {
        switch self {
        case .summarize: "Summarize"
        case .explain: "Explain Simply"
        case .learn: "Save to Learn"
        case .ask: "Ask About It"
        }
    }
}

@MainActor
enum PageActions {
    /// Reads the page in the front browser and does the action with it.
    static func perform(_ action: PageAction) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let b = BrowserReader.browser(for: front) ?? lastBrowser() else {
            IslandManager.shared.confirm("safari", "Open a page in your browser first", tint: DS.Ink.secondary)
            return
        }
        BrowserReader.page(in: b) { page in
            BrowserReader.text(in: b) { text in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { act(action, page: page, text: text, browser: b) }
                }
            }
        }
    }

    private static func lastBrowser() -> BrowserReader.Browser? {
        NSWorkspace.shared.runningApplications.lazy.compactMap { BrowserReader.browser(for: $0.bundleIdentifier) }.first
    }

    private static func act(_ action: PageAction, page: BrowserReader.Page?, text: BrowserReader.Text, browser: BrowserReader.Browser) {
        let title = page?.title ?? "this page"
        switch text {
        case .notAllowed(let name):
            IslandManager.shared.confirm("lock.shield", "Allow JavaScript from Apple Events in \(name)", tint: DS.Palette.orange)
            BrainAgent.shared.noteAction(BrowserReader.howToAllow(name), symbol: "lock.shield")
            return
        case .notPermitted(let name):
            IslandManager.shared.confirm("lock.shield", "Allow Mac Flow to control \(name)", tint: DS.Palette.orange)
            BrainAgent.shared.noteAction("Mac Flow needs permission to read \(name): System Settings › Privacy & Security › Automation › Mac Flow › \(name).", symbol: "lock.shield")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            return
        case .unavailable:
            IslandManager.shared.confirm("doc.questionmark", "Couldn’t read that page", tint: DS.Palette.orange)
            BrainAgent.shared.noteAction("Couldn’t read the page in \(browser.name) — is a web page (not a PDF or a new tab) in front?", symbol: "doc.questionmark")
            return
        case .text(let body):
            if let page { Memory.shared.remember([(id: "read.\(UUID(stable: page.url.absoluteString).uuidString).\(DayPlan.key())", date: Date(), kind: "read", text: "Read “\(page.title)” (\(page.url.host ?? ""))")]) }
            // For a question in the chat: its session's tools and context leave room for only a short excerpt.
            let context = "Page: \(title)\(page.map { " — \($0.url.absoluteString)" } ?? "")\n\n\(Mind.excerpt(body, 2200))"
            switch action {
            case .summarize:
                IslandManager.shared.primary?.model.openBrain()
                BrainAgent.shared.page("Summarize “\(title.prefix(70))”", instruction: "Summarize this page in three short bullets, then one line on why it matters.",
                                       title: title, text: body)
            case .explain:
                IslandManager.shared.primary?.model.openBrain()
                BrainAgent.shared.page("Explain “\(title.prefix(70))”", instruction: "Explain this page simply, as if I'm new to the topic — five sentences at most.",
                                       title: title, text: body)
            case .ask:
                IslandManager.shared.primary?.model.openBrain()
                BrainAgent.shared.draftContext(context, about: title)
            case .learn:
                LearnStore.shared.make(from: body, title: title, url: page?.url)
            }
        }
    }

}
