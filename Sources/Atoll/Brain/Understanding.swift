import Foundation

/// What you're doing, in the words a person would use.
enum WorkMode: String, CaseIterable, Codable, Sendable {
    case coding, writing, design, meeting, communicating, research, planning, media, reading, other, idle

    var label: String {
        switch self {
        case .coding: "Coding"
        case .writing: "Writing"
        case .design: "Designing"
        case .meeting: "In a meeting"
        case .communicating: "Messages & mail"
        case .research: "Researching"
        case .planning: "Planning"
        case .media: "Watching & listening"
        case .reading: "Reading"
        case .other: "Working"
        case .idle: "Away"
        }
    }

    var symbol: String {
        switch self {
        case .coding: "chevron.left.forwardslash.chevron.right"
        case .writing: "pencil.line"
        case .design: "paintbrush.pointed.fill"
        case .meeting: "video.fill"
        case .communicating: "bubble.left.and.bubble.right.fill"
        case .research: "magnifyingglass"
        case .planning: "calendar"
        case .media: "play.rectangle.fill"
        case .reading: "book.fill"
        case .other: "square.grid.2x2.fill"
        case .idle: "moon.zzz.fill"
        }
    }

    /// Modes that count as focused work.
    var isDeepWork: Bool { [.coding, .writing, .design, .planning].contains(self) }
}

/// Classifies an app (and, when known, its window title) into a mode. Rules first; a learned override from your
/// answers wins ("Is Notion work or personal?").
enum Understanding {
    private static let byBundle: [String: WorkMode] = [
        // Building
        "com.apple.dt.Xcode": .coding, "com.microsoft.VSCode": .coding, "com.todesktop.230313mzl4w4u92": .coding,
        "dev.zed.Zed": .coding, "com.sublimetext.4": .coding, "com.panic.Nova": .coding, "com.apple.Terminal": .coding,
        "com.googlecode.iterm2": .coding, "com.mitchellh.ghostty": .coding, "dev.warp.Warp-Stable": .coding,
        "com.github.GitHubClient": .coding, "com.tower.Tower3": .coding, "com.postmanlabs.mac": .coding,
        // Writing
        "com.apple.iWork.Pages": .writing, "com.microsoft.Word": .writing, "notion.id": .writing, "md.obsidian": .writing,
        "net.shinyfrog.bear": .writing, "com.apple.Notes": .writing, "com.ulyssesapp.mac": .writing, "com.apple.TextEdit": .writing,
        "pro.writer.mac": .writing, "com.craft.mac": .writing,
        // Design
        "com.figma.Desktop": .design, "com.bohemiancoding.sketch3": .design, "com.adobe.Photoshop": .design,
        "com.adobe.illustrator": .design, "com.seriflabs.affinitydesigner2": .design, "com.pixelmatorteam.pixelmator.x": .design,
        "com.apple.iWork.Keynote": .design, "com.apple.FinalCut": .design, "com.blackmagic-design.DaVinciResolve": .design,
        // Meetings
        "us.zoom.xos": .meeting, "com.microsoft.teams2": .meeting, "com.microsoft.teams": .meeting, "com.apple.FaceTime": .meeting,
        "com.cisco.webexmeetingsapp": .meeting,
        // Conversations
        "com.apple.mail": .communicating, "com.tinyspeck.slackmacgap": .communicating, "com.apple.MobileSMS": .communicating,
        "net.whatsapp.WhatsApp": .communicating, "desktop.WhatsApp": .communicating, "ru.keepcoder.Telegram": .communicating,
        "com.hnc.Discord": .communicating, "com.microsoft.Outlook": .communicating, "com.readdle.smartemail-Mac": .communicating,
        "com.superhuman.electron": .communicating,
        // Planning
        "com.apple.iCal": .planning, "com.apple.reminders": .planning, "com.culturedcode.ThingsMac": .planning,
        "com.omnigroup.OmniFocus4": .planning, "com.linear": .planning, "com.apple.iWork.Numbers": .planning,
        "com.microsoft.Excel": .planning,
        // Watching & listening
        "com.apple.Music": .media, "com.spotify.client": .media, "com.apple.TV": .media, "com.apple.podcasts": .media,
        "org.videolan.vlc": .media, "com.colliderli.iina": .media, "com.apple.QuickTimePlayerX": .media,
        // Reading
        "com.apple.iBooksX": .reading, "com.amazon.Lassen": .reading, "com.apple.Preview": .reading, "net.readkit.ReadKit": .reading,
    ]

    private static let browsers: Set<String> = [
        "com.apple.Safari", "com.google.Chrome", "company.thebrowser.Browser", "org.mozilla.firefox", "com.microsoft.edgemac",
        "com.brave.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    static func isBrowser(_ bundle: String) -> Bool { browsers.contains(bundle) }

    /// Mode for an app and its window title.
    static func mode(bundle: String, title: String, overrides: [String: WorkMode] = [:]) -> WorkMode {
        if let o = overrides[bundle] { return o }
        if browsers.contains(bundle) { return webMode(title) }
        if bundle == ClaudeSessions.desktopBundleID { return .coding }
        return byBundle[bundle] ?? .other
    }

    /// A browser tab says what you're doing better than the browser does.
    static func webMode(_ title: String) -> WorkMode {
        let t = title.lowercased()
        let rules: [(WorkMode, [String])] = [
            (.coding, ["github", "gitlab", "stack overflow", "localhost", "vercel", "supabase", "developer.apple", "docs.rs", "npm", "pull request", "issue #"]),
            (.meeting, ["meet.google", "google meet", "zoom meeting", "teams meeting", "whereby"]),
            (.communicating, ["gmail", "inbox", "outlook", "slack", "whatsapp", "messenger", "linkedin messaging"]),
            (.writing, ["google docs", "docs.google", "notion", "medium", "substack editor", "dropbox paper"]),
            (.design, ["figma", "canva", "dribbble", "framer"]),
            (.planning, ["google sheets", "calendar", "linear", "jira", "asana", "trello", "airtable"]),
            (.media, ["youtube", "netflix", "prime video", "twitch", "spotify", "soundcloud", "apple music", "disney+"]),
            (.reading, ["wikipedia", "arxiv", "kindle", "pdf"]),
        ]
        for (mode, words) in rules where words.contains(where: t.contains) { return mode }
        return .research
    }

    /// The project a window belongs to, from its title — using projects already known (Claude folders, past answers)
    /// first, then each editor's own title convention.
    static func project(bundle: String, title: String, known: [String]) -> String? {
        let parts = title
            .replacingOccurrences(of: " – ", with: " — ")
            .replacingOccurrences(of: " - ", with: " — ")
            .components(separatedBy: " — ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let lowerKnown = known.map { ($0, $0.lowercased()) }
        for part in parts {
            let p = part.lowercased()
            if let hit = lowerKnown.first(where: { p == $0.1 || p.hasPrefix($0.1 + " ") || p.contains("/" + $0.1) }) { return hit.0 }
        }
        guard !parts.isEmpty else { return nil }
        switch bundle {
        case "com.apple.dt.Xcode": return parts.first
        case "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92", "dev.zed.Zed": return parts.count > 1 ? parts.last : nil
        case "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty":
            // "Atoll — zsh — 80×24" or "~/Projects/Atoll"
            let first = parts.first ?? ""
            if first.contains("/") { return URL(fileURLWithPath: (first as NSString).expandingTildeInPath).lastPathComponent }
            return ["zsh", "bash", "fish", "-zsh"].contains(first) ? nil : first
        default: return nil
        }
    }

    /// Windows that must never be recorded.
    static func isPrivate(bundle: String, title: String) -> Bool {
        let neverApps: Set<String> = ["com.1password.1password", "com.agilebits.onepassword7", "com.bitwarden.desktop",
                                      "com.apple.keychainaccess", "com.apple.Passwords", "com.dashlane.dashlanephonefinal"]
        if neverApps.contains(bundle) { return true }
        let t = title.lowercased()
        return t.contains("private browsing") || t.contains("incognito") || t.contains("inprivate")
    }
}
