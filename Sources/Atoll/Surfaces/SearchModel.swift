import AppKit
import SwiftUI
import Combine

enum SearchScope: Int, CaseIterable, Identifiable {
    case all, apps, files, actions, clipboard
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .apps: "Applications"
        case .files: "Files"
        case .actions: "Actions"
        case .clipboard: "Clipboard"
        }
    }

    var symbol: String {
        switch self {
        case .all: "magnifyingglass"
        case .apps: "square.grid.2x2"
        case .files: "doc"
        case .actions: "bolt"
        case .clipboard: "list.clipboard"
        }
    }

    var placeholder: String {
        switch self {
        case .all: "Search anything…"
        case .apps: "Search Applications"
        case .files: "Search Files"
        case .actions: "Search Actions"
        case .clipboard: "Search Clipboard"
        }
    }

    /// ⌘1–⌘4 select a scope; pressing it again returns to All.
    var shortcut: String? {
        switch self {
        case .all: nil
        case .apps: "1"
        case .files: "2"
        case .actions: "3"
        case .clipboard: "4"
        }
    }
}

struct Answer: Equatable {
    let copyValue: String
    let display: String
    let detail: String
    let symbol: String
}

enum SearchAction: Equatable {
    case command(SystemCommand)
    case shortcut(String)
    case settings(SettingsPane)
    case reminder(RemindersService.Draft)
    case timer(minutes: Int)
    case url(URL)
}

enum SearchResult: Identifiable, Equatable {
    case app(AppEntry)
    case file(FileHit)
    case answer(Answer)
    case action(SearchAction)
    case clip(ClipItem)
    case web(String)
    /// Ask Claude — `prompt` is what's sent, `title` what's shown.
    case ask(prompt: String, title: String)
    /// Ask Atoll's own Brain, which knows your day (on this Mac).
    case brain(String)
    /// Something you told Atoll to do ("volume 40", "airpods"), a project or a Claude session.
    case smart(SmartCommand)
    /// A "For You" card.
    case suggestion(Suggestion)

    var id: String {
        switch self {
        case .app(let a): "app:\(a.id)"
        case .file(let f): "file:\(f.id)"
        case .answer(let a): "ans:\(a.detail)"
        case .action(let a):
            switch a {
            case .command(let c): "cmd:\(c.rawValue)"
            case .shortcut(let s): "sc:\(s)"
            case .settings(let p): "set:\(p.id)"
            case .reminder(let d): "rem:\(d.title)"
            case .timer(let m): "tmr:\(m)"
            case .url(let u): "url:\(u.absoluteString)"
            }
        case .clip(let c): "clip:\(c.id)"
        case .web(let q): "web:\(q)"
        case .ask(_, let title): "ask:\(title)"
        case .brain(let q): "brain:\(q)"
        case .smart(let c): "smart:\(c.id)"
        case .suggestion(let s): "sug:\(s.id)"
        }
    }
}

struct SearchSection: Identifiable, Equatable {
    enum Style: Equatable { case list, iconRow, cards }
    let id: String
    let title: String
    var style: Style = .list
    var items: [SearchResult]
}

/// One place to find anything: apps, files, actions, the clipboard, answers and the web.
@MainActor
final class SearchModel: ObservableObject {
    static let shared = SearchModel()

    /// Whether the text field has keyboard focus. Until it does, Atoll types into the query itself.
    var fieldFocused = false
    @Published var query = "" { didSet { if query != oldValue { answering = false; recompute(reset: true) } } }
    /// Showing Claude's answer instead of results.
    @Published private(set) var answering = false
    enum AnswerSource { case claude, brain }
    @Published private(set) var answerSource: AnswerSource = .claude

    func showBrainAnswer() {
        answerSource = .brain
        withAnimation(Motion.morph) { answering = true }
    }

    static let answerHeight: CGFloat = 230

    #if DEBUG
    func debugShowAnswer() { answering = true }
    #endif

    func closeAnswer() {
        ClaudeAsk.shared.cancel()
        BrainChat.shared.cancel()
        withAnimation(Motion.morph) { answering = false }
    }
    @Published var scope: SearchScope = .all { didSet { if scope != oldValue { recompute(reset: true) } } }
    @Published private(set) var sections: [SearchSection] = []
    @Published var selection = 0 { didSet { if selection != oldValue { updateAccent() } } }
    @Published private(set) var confirmation: String?

    static let fieldHeight: CGFloat = 62
    static let rowHeight: CGFloat = 42
    static let headerHeight: CGFloat = 28
    static let iconRowHeight: CGFloat = 64
    static let cardsHeight: CGFloat = 92
    static let previewMinHeight: CGFloat = 248
    /// Whether you've moved the selection yourself since typing; until then it follows the top hit as results arrive.
    private var userMoved = false
    static let maxContentHeight: CGFloat = 400

    /// The colour of what's selected — the island takes it on as light.
    @Published private(set) var accent: Color?
    private var iconColors: [String: Color] = [:]

    private var cancellables = Set<AnyCancellable>()
    private var confirmWork: DispatchWorkItem?

    init() {
        FileSearch.shared.$hits
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recompute(reset: false) }
            .store(in: &cancellables)
        CurrencyRates.shared.$version
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.recompute(reset: false) }
            .store(in: &cancellables)
        ClipboardHistory.shared.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard self?.scope == .clipboard else { return }
                self?.recompute(reset: false)
            }
            .store(in: &cancellables)
    }

    // MARK: - Layout

    /// Selectable results in display order (icon rows are selectable item by item).
    var results: [SearchResult] { sections.flatMap(\.items) }

    var selected: SearchResult? {
        let all = results
        return all.indices.contains(selection) ? all[selection] : nil
    }

    var contentHeight: CGFloat {
        if answering { return Self.fieldHeight + Self.answerHeight }
        var h = Self.fieldHeight
        if sections.isEmpty {
            h += hint == nil ? 0 : 44
        } else {
            h += 8
            var list: CGFloat = 0
            for s in sections {
                list += Self.headerHeight
                switch s.style {
                case .iconRow: list += Self.iconRowHeight
                case .cards: list += Self.cardsHeight
                case .list: list += CGFloat(s.items.count) * Self.rowHeight
                }
            }
            h += (showsPreview ? max(list, Self.previewMinHeight) : list) + 12
            if query.isEmpty { h += 26 }   // the key hints
        }
        return min(h, Self.maxContentHeight)
    }

    /// Guidance when a scope has nothing to show yet.
    var hint: String? {
        guard sections.isEmpty else { return nil }
        switch scope {
        case .files: return query.isEmpty ? "Type to search files in your home folder." : (Prefs.shared.fileSearch ? "No files found." : "File search is turned off in Settings.")
        case .clipboard: return Prefs.shared.clipboardEnabled ? "Nothing copied yet." : "Clipboard history is turned off in Settings."
        default: return query.isEmpty ? nil : "No results."
        }
    }

    /// Typed queries show a preview of the selected result beside the list.
    var showsPreview: Bool {
        guard !query.isEmpty, let s = selected else { return false }
        switch s {
        case .file, .app, .answer, .smart, .clip: return true
        default: return false
        }
    }

    private func updateAccent() {
        let next: Color?
        switch selected {
        case .app(let e)?: next = iconColor(e)
        case .file?: next = DS.Palette.blue
        case .ask?: next = ClaudeSessions.tint
        case .brain?: next = BrainStyle.tint
        case .smart(let c)?: next = c.tint
        case .suggestion(let s)?: next = s.tint
        case .answer?: next = DS.Palette.orange
        case .web?: next = DS.Palette.blue
        default: next = nil
        }
        if next != accent { withAnimation(.easeInOut(duration: 0.35)) { accent = next } }
    }

    /// An app icon's vivid average colour, computed once off the main thread.
    private func iconColor(_ e: AppEntry) -> Color? {
        if let c = iconColors[e.id] { return c }
        let icon = AppCatalog.shared.icon(for: e)
        guard let cg = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        nonisolated(unsafe) let image = cg
        let id = e.id
        DispatchQueue.global(qos: .userInitiated).async {
            let color = Self.vivid(image)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let me = SearchModel.shared
                    me.iconColors[id] = color
                    if case .app(let sel)? = me.selected, sel.id == id { withAnimation(.easeInOut(duration: 0.35)) { me.accent = color } }
                }
            }
        }
        return accent
    }

    nonisolated private static func vivid(_ cg: CGImage) -> Color {
        let w = 6, h = 6
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let _ = Optional(ctx.interpolationQuality = .high) else { return .white }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return .white }
        var best: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 1, 0)
        for i in 0..<(w * h) where px[i * 4 + 3] > 200 {
            let c = NSColor(srgbRed: CGFloat(px[i * 4]) / 255, green: CGFloat(px[i * 4 + 1]) / 255, blue: CGFloat(px[i * 4 + 2]) / 255, alpha: 1)
            var hh: CGFloat = 0, ss: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
            c.getHue(&hh, saturation: &ss, brightness: &bb, alpha: &aa)
            let score = ss * bb
            if score > best.3 { best = (hh, ss, bb, score) }
        }
        if best.3 < 0.05 { return Color(white: 0.85) }
        return Color(hue: Double(best.0), saturation: Double(min(1, best.1 * 1.1)), brightness: Double(max(best.2, 0.85)))
    }

    // MARK: - Lifecycle

    func reset() {
        if answering { closeAnswer() }
        query = ""
        scope = .all
        selection = 0
        confirmation = nil
        FileSearch.shared.search("")
    }

    func prepare() {
        AppCatalog.shared.refreshIfStale()
        ShortcutsService.shared.refreshIfStale()
        recompute(reset: true)
    }

    func confirm(_ text: String) {
        confirmWork?.cancel()
        withAnimation(.snappy) { confirmation = text }
        let work = DispatchWorkItem { [weak self] in withAnimation(.easeOut) { self?.confirmation = nil } }
        confirmWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
    }

    // MARK: - Results

    private func recompute(reset: Bool) {
        let previous = selected?.id
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if reset { FileSearch.shared.search(scope == .all || scope == .files ? q : "") }
        sections = q.isEmpty ? emptyState() : results(for: q)
        if reset || !userMoved {
            selection = 0
            if reset { userMoved = false }
        } else if let previous, let i = results.firstIndex(where: { $0.id == previous }) {
            selection = i
        } else {
            selection = min(selection, max(0, results.count - 1))
        }
        updateAccent()
    }

    private func emptyState() -> [SearchSection] {
        let catalog = AppCatalog.shared
        switch scope {
        case .all:
            var out: [SearchSection] = []
            let cards = Suggestion.forYou()
            if !cards.isEmpty { out.append(SearchSection(id: "foryou", title: "For You", style: .cards, items: cards.map(SearchResult.suggestion))) }
            var apps = catalog.recentEntries
            for p in catalog.pinnedEntries where !apps.contains(p) { apps.append(p) }
            let row = Array(apps.prefix(9))
            if !row.isEmpty { out.append(SearchSection(id: "suggested", title: "Apps", style: .iconRow, items: row.map(SearchResult.app))) }
            return out
        case .apps:
            let list = Array((catalog.recentEntries + catalog.pinnedEntries.filter { !catalog.recentEntries.contains($0) }).prefix(7))
            return list.isEmpty ? [] : [SearchSection(id: "apps", title: "Recent", items: list.map(SearchResult.app))]
        case .files:
            return []
        case .actions:
            let commands: [SystemCommand] = [.focus25, .keepAwake, .mirror, .colorPicker, .screenshot, .toggleDarkMode, .lockScreen]
            return [SearchSection(id: "actions", title: "Actions", items: commands.map { .action(.command($0)) })]
        case .clipboard:
            guard Prefs.shared.clipboardEnabled else { return [] }
            let clips = ClipboardHistory.shared.items.prefix(8)
            return clips.isEmpty ? [] : [SearchSection(id: "clips", title: "Recently Copied", items: clips.map(SearchResult.clip))]
        }
    }

    private func results(for q: String) -> [SearchSection] {
        var out: [SearchSection] = []
        let lower = q.lowercased()

        if scope == .clipboard {
            let clips = ClipboardHistory.shared.items.filter { $0.text.localizedCaseInsensitiveContains(q) }.prefix(8)
            return clips.isEmpty ? [] : [SearchSection(id: "clips", title: "Clipboard", items: clips.map(SearchResult.clip))]
        }

        var commanded = false
        if scope == .all || scope == .actions {
            let smart = SmartCommand.parse(q)
            if !smart.isEmpty { out.append(SearchSection(id: "do", title: "Do", items: smart.prefix(6).map(SearchResult.smart))) }
            // A clear instruction ("volume 40", "jbl", "next") doesn't need "Ask Claude …" under it; Tab still asks.
            commanded = smart.contains { if case .project = $0 { return false }; if case .claude = $0 { return false }; return true }
        }

        if scope == .all {
            var answers: [SearchResult] = []
            if let v = Calculator.evaluate(q) {
                let s = Calculator.format(v)
                answers.append(.answer(Answer(copyValue: s, display: s, detail: q, symbol: "equal")))
            }
            if let c = Converter.convert(q) {
                answers.append(.answer(Answer(copyValue: c.output, display: c.display, detail: c.detail, symbol: c.symbol)))
            }
            if !answers.isEmpty { out.append(SearchSection(id: "answer", title: "Answer", items: answers)) }
        }

        if scope == .all || scope == .actions {
            var actions: [SearchResult] = []
            if let draft = RemindersService.parse(q), !draft.title.isEmpty { actions.append(.action(.reminder(draft))) }
            if let minutes = Self.timerMinutes(lower) { actions.append(.action(.timer(minutes: minutes))) }
            if !actions.isEmpty { out.append(SearchSection(id: "quick", title: "Quick Actions", items: actions)) }
        }

        if scope == .all || scope == .apps {
            var apps: [SearchResult] = []
            if let url = Self.urlIfLooksLikeOne(q) { apps.append(.action(.url(url))) }
            apps += AppCatalog.shared.search(q, limit: scope == .apps ? 8 : 5).map(SearchResult.app)
            if !apps.isEmpty { out.append(SearchSection(id: "apps", title: "Applications", items: apps)) }
        }

        if scope == .all || scope == .files {
            let files = FileSearch.shared.hits.prefix(scope == .files ? 8 : 4)
            if !files.isEmpty { out.append(SearchSection(id: "files", title: "Files", items: files.map(SearchResult.file))) }
        }

        if scope == .all || scope == .actions {
            var system: [SearchResult] = SettingsPane.search(q).map { .action(.settings($0)) }
            system += ShortcutsService.shared.search(q, limit: 3).map { .action(.shortcut($0)) }
            if q.count >= 2 { system += SystemCommand.allCases.filter { $0.matches(q) }.prefix(3).map { .action(.command($0)) } }
            if !system.isEmpty { out.append(SearchSection(id: "system", title: scope == .actions ? "Actions" : "Actions & Settings", items: system)) }
        }

        if scope == .all {
            let claude = commanded ? [] : claudeResults(q, lower: lower)
            // A question goes to Claude first; anything else keeps Claude just above the web.
            let looksLikeQuestion = q.hasSuffix("?") || lower.hasPrefix("ask ") || lower.hasPrefix("claude ")
                || ["what ", "why ", "how ", "who ", "when ", "explain ", "write ", "summarize ", "summarise "].contains { lower.hasPrefix($0) }
            if !claude.isEmpty {
                let section = SearchSection(id: "claude", title: "Claude", items: claude)
                if looksLikeQuestion { out.insert(section, at: 0) } else { out.append(section) }
            }
            if !commanded { out.append(SearchSection(id: "web", title: "Web", items: [.web(q)])) }
        }
        return out
    }

    /// Ask Claude anything, or have it work on what you just copied.
    private func claudeResults(_ q: String, lower: String) -> [SearchResult] {
        guard q.count >= 2 else { return [] }
        var items: [SearchResult] = []
        var prompt = q
        for prefix in ["ask claude ", "ask ", "claude "] where lower.hasPrefix(prefix) {
            prompt = String(q.dropFirst(prefix.count))
            break
        }
        if !prompt.trimmingCharacters(in: .whitespaces).isEmpty {
            // Questions about you go to the Brain first; it knows your day.
            let personal = [" my ", " i ", "today", "yesterday", "this week", "did i", "was i", "have i", "should i", "what next", "remind"]
                .contains { (" " + lower + " ").contains($0) }
            if Mind.shared.isAvailable, Prefs.shared.brainLevel > 0 {
                if personal { items.insert(.brain(q), at: 0) } else { items.append(.brain(q)) }
            }
            items.insert(.ask(prompt: prompt, title: "Ask Claude “\(prompt)”"), at: personal && !items.isEmpty ? 1 : 0)
        }
        let clipWords = ["clip", "explain", "summar", "translat", "fix", "copied"]
        if clipWords.contains(where: { lower.contains($0) }),
           let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !clip.isEmpty {
            let text = String(clip.prefix(6000))
            items.append(.ask(prompt: "Explain this clearly and briefly:\n\n\(text)", title: "Explain what you copied"))
            items.append(.ask(prompt: "Summarize this in a few bullet points:\n\n\(text)", title: "Summarize what you copied"))
            items.append(.ask(prompt: "Translate this into English. Reply with only the translation:\n\n\(text)", title: "Translate what you copied"))
            items.append(.ask(prompt: "Fix the spelling and grammar. Reply with only the corrected text:\n\n\(text)", title: "Fix what you copied"))
        }
        return items
    }

    private static let timerPatterns: [NSRegularExpression] = [
        #"^(?:timer|focus)\s+(\d{1,3})\s*(?:m|min|mins|minutes?)?$"#, #"^(\d{1,3})\s*(?:m|min|mins|minutes?)\s+(?:timer|focus)$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func timerMinutes(_ q: String) -> Int? {
        for re in timerPatterns {
            if let m = re.firstMatch(in: q, range: NSRange(q.startIndex..., in: q)),
               let r = Range(m.range(at: 1), in: q), let n = Int(q[r]), (1...600).contains(n) {
                return n
            }
        }
        return nil
    }

    private static func urlIfLooksLikeOne(_ q: String) -> URL? {
        guard !q.contains(" "), q.contains(".") else { return nil }
        if q.hasPrefix("http://") || q.hasPrefix("https://") { return URL(string: q) }
        let parts = q.split(separator: ".")
        guard parts.count >= 2, let tld = parts.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        return URL(string: "https://\(q)")
    }

    // MARK: - Keyboard

    func move(_ delta: Int) {
        let count = results.count
        guard count > 0 else { return }
        userMoved = true
        selection = min(max(0, selection + delta), count - 1)
    }

    /// The pointer picked a row.
    func hoverSelect(_ i: Int) {
        guard i != selection else { return }
        userMoved = true
        selection = i
    }

    /// Tab: ask about what you typed — Atoll's Brain if it's about you, else Claude.
    func askAboutQuery() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        if let first = results.first(where: { if case .brain = $0 { return true }; if case .ask = $0 { return true }; return false }) {
            activate(first)
        } else {
            activate(.ask(prompt: q, title: "Ask Claude “\(q)”"))
        }
    }

    func cycleScope(_ s: SearchScope) {
        scope = scope == s ? .all : s
    }

    // MARK: - Activation

    func activateSelection(alternate: Bool = false) {
        guard let r = selected else { return }
        activate(r, alternate: alternate)
    }

    func activate(_ r: SearchResult, alternate: Bool = false) {
        let manager = IslandManager.shared
        switch r {
        case .app(let e):
            if alternate { AppCatalog.shared.reveal(e) } else { AppCatalog.shared.launch(e) }
            manager.collapseAll()
        case .file(let f):
            if alternate { NSWorkspace.shared.activateFileViewerSelecting([f.url]) } else { NSWorkspace.shared.open(f.url) }
            manager.collapseAll()
        case .answer(let a):
            guard !a.copyValue.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(a.copyValue, forType: .string)
            Haptics.confirm()
            confirm("Copied \(a.copyValue)")
        case .clip(let c):
            let pasted = ClipboardHistory.shared.use(c, paste: Prefs.shared.pasteOnReturn || alternate)
            Haptics.confirm()
            if !pasted { confirm("Copied") }
        case .web(let q):
            SystemActions.webSearch(q)
            manager.collapseAll()
        case .ask(let prompt, let title):
            ClaudeAsk.shared.ask(prompt, display: title)
            answerSource = .claude
            withAnimation(Motion.morph) { answering = true }
        case .brain(let q):
            // Atoll's conversation can also act on what you asked — it lives in its own place.
            IslandManager.shared.primary?.model.openBrain()
            BrainAgent.shared.send(q)
        case .action(let a):
            perform(a, alternate: alternate)
        case .smart(let c):
            Haptics.confirm()
            if let msg = c.perform() { confirm(msg); query = "" } else if c.staysInIsland { query = "" } else { manager.collapseAll() }
        case .suggestion(let s):
            switch s.action {
            case .brain(let a):
                BrainEngine.shared.perform(a)
                manager.collapseAll()
            case .smart(let c):
                if let msg = c.perform() { confirm(msg); recompute(reset: false) } else { manager.collapseAll() }
            case .ask(let prompt, let title):
                activate(.ask(prompt: prompt, title: title))
            case .openPlayer:
                NowPlayingModel.shared.openCurrentApp()
                manager.collapseAll()
            }
        }
    }

    private func perform(_ a: SearchAction, alternate: Bool) {
        let manager = IslandManager.shared
        switch a {
        case .command(let c):
            manager.perform(c)
        case .shortcut(let name):
            if alternate {
                ShortcutsService.shared.openEditor(name)
                manager.collapseAll()
            } else {
                ShortcutsService.shared.run(name)
                confirm("Running “\(name)”")
            }
        case .settings(let p):
            p.open()
            manager.collapseAll()
        case .reminder(let draft):
            RemindersService.shared.create(draft) { [weak self] ok in
                if ok {
                    Haptics.confirm()
                    self?.confirm("Reminder Added")
                    self?.query = ""
                } else {
                    self?.confirm("Couldn't add reminder")
                }
            }
        case .timer(let minutes):
            FocusTimer.shared.start(minutes: minutes, label: minutes <= 10 ? "Break" : "Focus")
            manager.collapseAll()
        case .url(let u):
            NSWorkspace.shared.open(u)
            manager.collapseAll()
        }
    }
}
