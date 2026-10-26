import SwiftUI
import QuickLookThumbnailing

/// Search, rebuilt as the island's command centre: what you need now before you type, your Mac under your words
/// as you type ("volume 40", "airpods", "play …"), and a preview of whatever is selected. The island takes on the
/// colour of the selection.
struct SearchView: View {
    var model: IslandModel
    @ObservedObject private var search = SearchModel.shared
    @FocusState private var focused: Bool
    @Environment(\.islandShowing) private var showing

    private var inset: CGFloat { IslandModel.expandedFlare + DS.Space.m }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notch.height)
            field
                .frame(height: SearchModel.fieldHeight)
                .padding(.horizontal, inset + 4)
            Rectangle().fill(DS.Ink.hairline).frame(height: 1).padding(.horizontal, inset + 8)
            if search.answering {
                Group {
                    if search.answerSource == .brain {
                        BrainAnswerPanel { search.closeAnswer() }
                    } else {
                        ClaudeAnswerPanel { search.closeAnswer() }
                    }
                }
                .padding(.horizontal, inset + DS.Space.s)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .frame(height: SearchModel.answerHeight)
            } else if search.sections.isEmpty {
                if let hint = search.hint {
                    Text(hint)
                        .font(DS.Kit.meta)
                        .foregroundStyle(DS.Ink.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, inset + DS.Space.m)
                        .frame(height: 44)
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    results
                    if search.showsPreview, let r = search.selected {
                        SearchPreview(result: r)
                            .frame(width: 236)
                            .padding(.top, 10)
                            .padding(.trailing, inset)
                            .transition(.identity)
                    }
                }
                if search.query.isEmpty { keyHints }
            }
            Spacer(minLength: 0)
        }
        .background(alignment: .top) {
            // The selection's colour, as light in the black.
            if let a = search.accent {
                ContentLight(color: a, origin: UnitPoint(x: 0.5, y: 1.15), strength: 0.7)
                    .animation(.easeInOut(duration: 0.35), value: a)
            }
        }
        .onAppear {
            search.prepare()
            if model.wantsSearchFocus {
                model.wantsSearchFocus = false
                focusAfterOpening()
            }
        }
        .onChange(of: model.focusSearchTick) { _, _ in focusAfterOpening() }
        // Kept alive between uses: refresh on show, let go of the keyboard on hide.
        .onChange(of: showing) { _, on in
            if on { search.prepare() } else { focused = false }
        }
        .onChange(of: focused) { _, now in
            search.fieldFocused = now
            if now, !search.query.isEmpty {
                DispatchQueue.main.async { NSApp.sendAction(#selector(NSResponder.moveToEndOfDocument(_:)), to: nil, from: nil) }
            }
        }
        .onDisappear { search.fieldFocused = false }
    }

    /// Taking keyboard focus wakes the input system, which costs a couple of frames — so it waits until the
    /// open spring has mostly settled. Keys typed before then are caught by IslandManager and added to the query.
    private func focusAfterOpening() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { focused = true }
    }

    // MARK: Field

    /// What Atoll thinks you mean, shown by the glyph before you press anything.
    private var intent: (symbol: String, tint: Color) {
        let q = search.query.lowercased()
        if q.isEmpty { return ("magnifyingglass", DS.Ink.secondary) }
        switch search.results.first {
        case .smart(let c)?: return (c.symbol, c.tint)
        case .answer(let a)?: return (a.symbol, DS.Palette.orange)
        case .ask?: return ("sparkle", ClaudeSessions.tint)
        case .brain?: return ("sparkles", BrainStyle.tint)
        case .action(.timer)?: return ("timer", DS.Palette.orange)
        case .action(.reminder)?: return ("checklist", DS.Palette.orange)
        default: return ("magnifyingglass", DS.Ink.secondary)
        }
    }

    private var field: some View {
        HStack(spacing: 14) {
            Image(systemName: intent.symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(intent.tint)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24)
                .animation(.snappy(duration: 0.25), value: intent.symbol)
                .accessibilityHidden(true)
            TextField("", text: $search.query,
                      prompt: Text(search.scope == .all ? "Search, ask, or tell Flow what to do" : search.scope.placeholder)
                        .foregroundColor(DS.Ink.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(DS.Ink.primary)
                .focused($focused)
                .accessibilityLabel(search.scope.placeholder)
            if let c = search.confirmation {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                    Text(c).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Capsule().fill(Color.white))
                .transition(.scale(scale: 0.85))
            }
            scopePicker
        }
        .padding(.leading, 6)
        .islandReveal(0)
    }

    private var scopePicker: some View {
        HStack(spacing: 0) {
            ForEach(SearchScope.allCases.filter { $0 != .all }) { s in
                let on = search.scope == s
                Button { search.cycleScope(s) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: s.symbol).font(.system(size: 11, weight: .semibold))
                        if on { Text(s.title).font(.system(size: 11, weight: .semibold)).lineLimit(1) }
                    }
                    .foregroundStyle(on ? Color.black : DS.Ink.tertiary)
                    .padding(.horizontal, on ? 10 : 7)
                    .frame(height: 26)
                    .background(Capsule().fill(on ? Color.white : .clear))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressStyle())
                .help("\(s.title)  ⌘\(s.shortcut ?? "")")
                .accessibilityLabel(s.title)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.22), value: search.scope)
    }

    private var keyHints: some View {
        HStack(spacing: 14) {
            hint("↩", "open")
            hint("⇥", "ask")
            hint("⌘1–4", "filter")
            Spacer()
            Text("Try “volume 40”, “airpods”, “play …”")
                .font(.system(size: 11)).foregroundStyle(DS.Ink.tertiary)
        }
        .padding(.horizontal, inset + DS.Space.m)
        .frame(height: 26)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key).font(.system(size: 10, weight: .semibold, design: .rounded))
                .padding(.horizontal, 5).frame(height: 16)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(DS.Ink.well))
            Text(label).font(.system(size: 11))
        }
        .foregroundStyle(DS.Ink.tertiary)
    }

    // MARK: Results

    private var results: some View {
        let ids = search.results.map(\.id)
        return ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(search.sections) { section in
                        Eyebrow(text: section.title)
                            .padding(.leading, DS.Space.m)
                            .frame(height: SearchModel.headerHeight, alignment: .bottomLeading)
                            .padding(.bottom, 4)
                        switch section.style {
                        case .cards: cards(section, ids: ids)
                        case .iconRow: iconRow(section, ids: ids)
                        case .list:
                            ForEach(section.items) { r in
                                let i = ids.firstIndex(of: r.id) ?? 0
                                SearchRow(result: r, selected: i == search.selection)
                                    .id(r.id)
                                    .onTapGesture { search.activate(r) }
                                    .onHover { if $0 { search.hoverSelect(i) } }
                            }
                        }
                    }
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
                .padding(.leading, inset)
                .padding(.trailing, search.showsPreview ? 0 : inset)
            }
            .onChange(of: search.selection) { _, s in
                guard ids.indices.contains(s) else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(ids[s], anchor: .center) }
            }
        }
    }

    private func cards(_ section: SearchSection, ids: [String]) -> some View {
        HStack(spacing: 10) {
            ForEach(section.items) { r in
                if case .suggestion(let s) = r {
                    let i = ids.firstIndex(of: r.id) ?? 0
                    SuggestionCard(suggestion: s, selected: i == search.selection)
                        .id(r.id)
                        .onTapGesture { search.activate(r) }
                        .onHover { if $0 { search.hoverSelect(i) } }
                }
            }
        }
        .frame(height: SearchModel.cardsHeight - 8, alignment: .top)
        .padding(.bottom, 8)
    }

    private func iconRow(_ section: SearchSection, ids: [String]) -> some View {
        HStack(spacing: 6) {
            ForEach(section.items) { r in
                if case .app(let e) = r {
                    let i = ids.firstIndex(of: r.id) ?? 0
                    let on = i == search.selection
                    VStack(spacing: 5) {
                        IconImage(image: AppCatalog.shared.icon(for: e), size: 34)
                            .scaleEffect(on ? 1.08 : 1)
                            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: on)
                        Text(e.name)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(on ? DS.Ink.primary : DS.Ink.tertiary)
                            .lineLimit(1)
                    }
                    .frame(width: 58, height: SearchModel.iconRowHeight - 6)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? DS.Ink.well : .clear))
                    .contentShape(Rectangle())
                    .id(r.id)
                    .onTapGesture { search.activate(r) }
                    .onHover { if $0 { search.hoverSelect(i) } }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(e.name)
                    .accessibilityAddTraits(.isButton)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: SearchModel.iconRowHeight)
    }
}

// MARK: - For You card

struct SuggestionCard: View {
    let suggestion: Suggestion
    let selected: Bool
    @ObservedObject private var media = NowPlayingModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if suggestion.artwork {
                    LeadArtwork().frame(width: 18, height: 18)
                } else {
                    Image(systemName: suggestion.symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(suggestion.tint)
                        .frame(width: 18, height: 18)
                }
                Text(suggestion.eyebrow.uppercased())
                    .font(DS.Kit.eyebrow).tracking(DS.Kit.eyebrowTracking)
                    .foregroundStyle(DS.Ink.tertiary)
                    .lineLimit(1)
            }
            Text(suggestion.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.Ink.primary)
                .lineLimit(1)
            Text(suggestion.detail)
                .font(.system(size: 11))
                .foregroundStyle(DS.Ink.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.11 : 0.06))
                .overlay(alignment: .bottomLeading) {
                    // The card's own colour, rising from its corner.
                    Image.glow(Glow.radial)
                        .foregroundStyle(suggestion.tint.opacity(selected ? 0.34 : 0.2))
                        .frame(width: 280, height: 280)
                        .offset(x: -140, y: 140)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.white.opacity(selected ? 0.22 : 0.06), lineWidth: 0.5))
        }
        .scaleEffect(selected ? 1.0 : 0.985)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(suggestion.eyebrow): \(suggestion.title). \(suggestion.detail)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Preview

/// What the selected result is, larger: a file's thumbnail, an answer's figure, a level you're about to set.
struct SearchPreview: View {
    let result: SearchResult
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            visual
                .frame(maxWidth: .infinity)
                .frame(height: 118)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.Ink.primary).lineLimit(2)
                ForEach(details, id: \.self) { d in
                    Text(d).font(.system(size: 11)).foregroundStyle(DS.Ink.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .task(id: result.id) { await loadThumbnail() }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var visual: some View {
        switch result {
        case .file(let f):
            if let thumbnail {
                Image(nsImage: thumbnail).resizable().aspectRatio(contentMode: .fit).padding(10)
            } else {
                IconImage(image: f.icon, size: 64)
            }
        case .app(let e):
            IconImage(image: AppCatalog.shared.icon(for: e), size: 72)
        case .answer(let a):
            Text(a.display)
                .font(.system(size: 30, weight: .light, design: .rounded).monospacedDigit())
                .foregroundStyle(DS.Ink.primary)
                .minimumScaleFactor(0.4).lineLimit(1).padding(.horizontal, 12)
        case .smart(let c):
            VStack(spacing: 12) {
                Image(systemName: c.symbol).font(.system(size: 28, weight: .medium)).foregroundStyle(c.tint)
                if let level = c.level {
                    Capsule().fill(DS.Ink.well).frame(width: 150, height: 6)
                        .overlay(alignment: .leading) { Capsule().fill(c.tint).frame(width: max(6, 150 * level), height: 6) }
                }
            }
        case .clip(let c):
            Text(c.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DS.Ink.secondary)
                .lineLimit(7)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:
            EmptyView()
        }
    }

    private var title: String {
        switch result {
        case .file(let f): f.name
        case .app(let e): e.name
        case .answer(let a): a.display
        case .smart(let c): c.title
        case .clip: "Copied text"
        default: ""
        }
    }

    private var details: [String] {
        switch result {
        case .file(let f):
            var d = [f.folder]
            if let m = f.modified { d.append("Modified \(m.formatted(.relative(presentation: .named)))") }
            if let s = f.size { d.append(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)) }
            return d
        case .app(let e): return [e.id.replacingOccurrences(of: NSHomeDirectory(), with: "~"), "⌘↩ Show in Finder"]
        case .answer(let a): return [a.detail, "↩ Copy  ·  ⇥ Ask"]
        case .smart(let c):
            var d = [c.subtitle].compactMap { $0 }
            if case .playArtist(let a) = c,
               let plays = InsightModel.shared.insight.taste.topArtists.first(where: { $0.name.localizedCaseInsensitiveCompare(a) == .orderedSame })?.plays {
                d.append("You’ve played them \(plays) times this month")
            }
            d.append("↩ \(c.actionHint)")
            return d
        case .clip(let c): return [c.date.formatted(.relative(presentation: .named)), Prefs.shared.pasteOnReturn ? "↩ Paste" : "↩ Copy"]
        default: return []
        }
    }

    private func loadThumbnail() async {
        thumbnail = nil
        guard case .file(let f) = result else { return }
        let request = QLThumbnailGenerator.Request(fileAt: f.url, size: CGSize(width: 200, height: 110), scale: 2, representationTypes: .thumbnail)
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            thumbnail = rep.nsImage
        }
    }
}

struct SearchRow: View {
    let result: SearchResult
    let selected: Bool
    /// Beside a preview the row stays lean: the preview already says what Return does.
    var compact: Bool { SearchModel.shared.showsPreview }

    var body: some View {
        HStack(spacing: DS.Space.m) {
            icon.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(DS.Ink.primary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(DS.Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: DS.Space.s)
            if !compact, case .smart(let c) = result, let level = c.level {
                Capsule().fill(DS.Ink.well).frame(width: 64, height: 4)
                    .overlay(alignment: .leading) { Capsule().fill(c.tint).frame(width: max(4, 64 * level), height: 4) }
            }
            if selected {
                if !compact {
                    Text(actionHint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(DS.Ink.secondary)
                }
                KeyCap(text: "↩")
            }
        }
        .padding(.horizontal, DS.Space.m)
        .frame(height: SearchModel.rowHeight)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Color.white.opacity(0.1) : .clear))
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, subtitle].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var icon: some View {
        switch result {
        case .app(let e): IconImage(image: AppCatalog.shared.icon(for: e), size: 26)
        case .file(let f): IconImage(image: f.icon, size: 26)
        case .clip(let c): clipIcon(c)
        case .answer(let a): glyph(a.symbol, DS.Palette.orange)
        case .web: glyph("safari", DS.Palette.blue)
        case .ask: ClaudeGlyph(size: 18, spinning: false).frame(width: 28, height: 28)
        case .brain: FlowGlyph(size: 14).frame(width: 28, height: 28)
        case .smart(let c):
            if case .claude = c { ClaudeGlyph(size: 18, spinning: false).frame(width: 28, height: 28) } else { glyph(c.symbol, c.tint) }
        case .suggestion(let s): glyph(s.symbol, s.tint)
        case .action(let a):
            switch a {
            case .command(let c): glyph(c.symbol, DS.Palette.indigo)
            case .shortcut: glyph("square.stack.3d.up.fill", Color(red: 1, green: 0.27, blue: 0.47))
            case .settings(let p): glyph(p.symbol, Color(white: 0.45))
            case .reminder: glyph("checklist", DS.Palette.orange)
            case .timer: glyph("timer", DS.Palette.orange)
            case .url: glyph("link", DS.Palette.blue)
            }
        }
    }

    /// A glyph in its colour on a soft well of the same colour — no flat coloured squares.
    private func glyph(_ symbol: String, _ tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.16)))
    }

    @ViewBuilder
    private func clipIcon(_ c: ClipItem) -> some View {
        switch c.flavor {
        case .color:
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(ClipItem.color(from: c.text) ?? .gray)
        case .image:
            if let img = ClipboardHistory.shared.image(for: c) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else { glyph("photo", Color(white: 0.45)) }
        case .link: glyph("link", DS.Palette.blue)
        case .files: glyph("doc.fill", DS.Palette.cyan)
        case .code: glyph("chevron.left.forwardslash.chevron.right", DS.Palette.orange)
        default:
            if let icon = ClipboardHistory.appIcon(for: c.appBundleID) { IconImage(image: icon, size: 26) } else { glyph("text.alignleft", Color(white: 0.45)) }
        }
    }

    private var title: String {
        switch result {
        case .app(let e): e.name
        case .file(let f): f.name
        case .answer(let a): a.display
        case .clip(let c): c.text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        case .web(let q): "Search the Web for “\(q)”"
        case .ask(_, let title): title
        case .brain(let q): "Ask Flow “\(q)”"
        case .smart(let c): c.title
        case .suggestion(let s): s.title
        case .action(let a):
            switch a {
            case .command(let c): c.title
            case .shortcut(let n): n
            case .settings(let p): p.title
            case .reminder(let d): "Remind Me: \(d.title)"
            case .timer(let m): "Start \(m)-Minute Timer"
            case .url(let u): u.host ?? u.absoluteString
            }
        }
    }

    private var subtitle: String? {
        switch result {
        case .app: nil
        case .file(let f): f.folder
        case .answer(let a): a.detail
        case .clip(let c): c.date.formatted(.relative(presentation: .named))
        case .web: nil
        case .ask: ClaudeAsk.shared.signedIn == false ? "Opens Claude — sign in once to answer here" : "Answers right here"
        case .brain: "Knows your day · on this Mac"
        case .smart(let c): c.subtitle
        case .suggestion(let s): s.detail
        case .action(let a):
            switch a {
            case .command: nil
            case .shortcut: "Shortcut"
            case .settings: "System Settings"
            case .reminder(let d): d.due.map { RemindersService.describe($0) } ?? "Reminders"
            case .timer: nil
            case .url(let u): u.absoluteString
            }
        }
    }

    private var actionHint: String {
        switch result {
        case .app, .file, .web: "Open"
        case .ask, .brain: "Ask"
        case .smart(let c): c.actionHint
        case .suggestion: "Open"
        case .answer: "Copy"
        case .clip: Prefs.shared.pasteOnReturn ? "Paste" : "Copy"
        case .action(let a):
            switch a {
            case .reminder: "Add"
            case .shortcut: "Run"
            case .timer: "Start"
            default: "Open"
            }
        }
    }
}
