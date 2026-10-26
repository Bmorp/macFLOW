import AppKit
import SwiftUI
import NaturalLanguage
import PDFKit
import Vision

/// Flow Lens: copy something worth acting on — a time and a place, a long passage, a message that asks you something,
/// a line in another language — and the notch offers what you'd do next. Drop a PDF, an image or a text file on the
/// notch and Flow reads it. Everything is understood on this Mac; nothing is sent anywhere. Most copies show nothing:
/// only ones with an obvious next step, and not more than once a minute.
enum LensAction: Equatable, Identifiable {
    case addEvent(Date, String)
    case remind(String)
    case summarize(String)
    case tasks(String)
    case translate(String)
    case reply(String)
    case learn(String)

    var id: String {
        switch self {
        case .addEvent: "event"
        case .remind: "remind"
        case .summarize: "summarize"
        case .tasks: "tasks"
        case .translate: "translate"
        case .reply: "reply"
        case .learn: "learn"
        }
    }

    var title: String {
        switch self {
        case .addEvent: "Add to Calendar"
        case .remind: "Remind Me"
        case .summarize: "Summarize"
        case .tasks: "Find Tasks"
        case .translate: "Translate"
        case .reply: "Draft Reply"
        case .learn: "Save to Learn"
        }
    }

    var symbol: String {
        switch self {
        case .addEvent: "calendar.badge.plus"
        case .remind: "checklist"
        case .summarize: "text.alignleft"
        case .tasks: "checkmark.circle"
        case .translate: "character.bubble"
        case .reply: "arrowshape.turn.up.left"
        case .learn: "rectangle.stack.badge.plus"
        }
    }
}

struct LensItem: Equatable, Identifiable {
    var id = UUID()
    /// What it is ("Copied text", "Launch brief.pdf").
    let source: String
    /// A line of it.
    let snippet: String
    let actions: [LensAction]
}

// MARK: - Understanding (pure; tested)

enum LensReader {
    /// The next steps a piece of text invites — at most three, most specific first; none for most copies.
    static func actions(for raw: String, now: Date = Date()) -> [LensAction] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 8, !looksLikeLink(text), !looksLikeCode(text), !looksLikeSecret(text) else { return [] }
        var out: [LensAction] = []

        // A time in a short line: an event, or a reminder.
        if text.count <= 220, let (date, title) = event(in: text, now: now) {
            out.append(.addEvent(date, title))
            out.append(.remind(text))
        }
        // Another language.
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if text.count >= 15, let lang = recognizer.dominantLanguage, lang != .english, lang != .undetermined,
           (recognizer.languageHypotheses(withMaximum: 1)[lang] ?? 0) > 0.8 {
            out.append(.translate(text))
        }
        // A long passage.
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).filter { $0.trimmingCharacters(in: .whitespaces).count > 12 }
        if text.count >= 280 || sentences.count >= 4 {
            out.append(.summarize(text))
            out.append(.learn(text))
            out.append(.tasks(text))
        }
        // A message that asks something of you.
        let lower = text.lowercased()
        if text.count >= 30, text.count <= 1500, text.contains("?"),
           ["can you", "could you", "would you", "are you", "do you", "please", "let me know", "when can", "hi ", "hey ", "hello"].contains(where: lower.contains) {
            out.append(.reply(text))
        }
        var seen = Set<String>()
        return Array(out.filter { seen.insert($0.id).inserted }.prefix(3))
    }

    /// "Lunch with Sam Friday 1pm" → (Friday 1 PM, "Lunch with Sam"). Only dates with a time or a day word, and not in
    /// the past or more than two months out.
    static func event(in text: String, now: Date) -> (Date, String)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
              let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), let date = match.date,
              date > now.addingTimeInterval(-1800), date < now.addingTimeInterval(62 * 86_400),
              let r = Range(match.range, in: text) else { return nil }
        let phrase = text[r].lowercased()
        let hasTime = phrase.range(of: #"\d"#, options: .regularExpression) != nil || phrase.contains("noon")
        let dayWords = ["today", "tomorrow", "tonight", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "next"]
        guard hasTime || dayWords.contains(where: phrase.contains) else { return nil }
        var title = text.replacingCharacters(in: r, with: " ")
        title = title.replacingOccurrences(of: #"\b(at|on|from|this|for)\b\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        title = title.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.-–:;"))
        if title.isEmpty { title = "Event" }
        return (date, String(title.prefix(80)))
    }

    static func looksLikeLink(_ t: String) -> Bool {
        !t.contains(" ") && (t.hasPrefix("http") || t.hasPrefix("www.") || t.contains("://"))
    }

    static func looksLikeCode(_ t: String) -> Bool {
        let marks = [";", "{", "}", "=>", "func ", "let ", "var ", "const ", "import ", "def ", "</", "/>", "()"]
        return marks.filter(t.contains).count >= 2
    }

    /// Tokens, keys, hashes: one long run of mixed characters with no spaces.
    static func looksLikeSecret(_ t: String) -> Bool {
        !t.contains(" ") && t.count >= 20 && t.rangeOfCharacter(from: .decimalDigits) != nil && t.rangeOfCharacter(from: .letters) != nil
    }

    /// The text of a dropped file: a PDF's words, the words in an image, or a text file. Off the main thread.
    nonisolated static func text(of url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            return PDFDocument(url: url)?.string.map { String($0.prefix(12_000)) }
        }
        if ["png", "jpg", "jpeg", "heic", "tiff", "gif", "webp"].contains(ext) {
            guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
        if ["txt", "md", "markdown", "rtf", "csv", "json", "log", "html"].contains(ext) {
            if ext == "rtf", let a = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) { return String(a.string.prefix(12_000)) }
            return (try? String(contentsOf: url, encoding: .utf8)).map { String($0.prefix(12_000)) }
        }
        return nil
    }
}

// MARK: - The lens

@MainActor
final class LensModel {
    static let shared = LensModel()
    private var lastShown = Date.distantPast
    private var lastText = ""
    private var watch: Any?

    func start() {
        guard watch == nil else { return }
        watch = ClipboardHistory.shared.$items.dropFirst()
            .receive(on: RunLoop.main)
            .sink { items in LensModel.shared.copied(items.first) }
    }

    private func copied(_ clip: ClipItem?) {
        guard Prefs.shared.flowLens, let clip, clip.kind == .text, clip.text != lastText,
              clip.appBundleID != Bundle.main.bundleIdentifier, Date().timeIntervalSince(clip.date) < 5,
              Date().timeIntervalSince(lastShown) > 60, ActivityCenter.shared.call == nil,
              !Prefs.shared.brainExcluded.contains(clip.appBundleID ?? "") else { return }
        lastText = clip.text
        let actions = LensReader.actions(for: clip.text)
        guard !actions.isEmpty else { return }
        lastShown = Date()
        show(LensItem(source: "Copied text", snippet: Self.snippet(clip.text), actions: actions))
    }

    /// Files dropped on the notch's Flow target.
    func understand(_ urls: [URL]) {
        guard let url = urls.first else { return }
        let name = url.lastPathComponent
        IslandManager.shared.confirm("doc.text.magnifyingglass", "Reading \(name)…", tint: BrainStyle.tint)
        DispatchQueue.global(qos: .userInitiated).async {
            let text = LensReader.text(of: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let text, text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 20 else {
                        IslandManager.shared.confirm("questionmark.folder", "No words to read in \(name)", tint: DS.Palette.orange)
                        return
                    }
                    var actions: [LensAction] = [.summarize(text), .learn(text), .tasks(text)]
                    if let (date, title) = LensReader.event(in: String(text.prefix(220)), now: Date()) { actions.insert(.addEvent(date, title), at: 0) }
                    LensModel.shared.show(LensItem(source: name, snippet: Self.snippet(text), actions: Array(actions.prefix(3))))
                }
            }
        }
    }

    private func show(_ item: LensItem) {
        guard let model = IslandManager.shared.primary?.model else { return }
        model.showAlert(.lens(item), duration: 8)
    }

    static func snippet(_ text: String) -> String {
        let one = text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return one.count > 90 ? String(one.prefix(88)) + "…" : one
    }

    // MARK: Acting

    func perform(_ action: LensAction) {
        let manager = IslandManager.shared
        switch action {
        case .addEvent(let date, let title):
            if CalendarModel.shared.addEvent(title: title, start: date, minutes: 30) {
                manager.confirm("calendar.badge.checkmark", "\(title) · \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))", tint: DS.Palette.green)
            } else {
                manager.confirm("calendar.badge.exclamationmark", "Allow Calendar access in Settings › Permissions", tint: DS.Palette.orange)
            }
        case .remind(let text):
            if let draft = RemindersService.parse("remind me to " + text) ?? RemindersService.parse(text) {
                RemindersService.shared.create(draft) { ok in
                    IslandManager.shared.confirm(ok ? "checklist" : "exclamationmark.triangle", ok ? "Reminder: \(draft.title)" : "Couldn’t add the reminder",
                                                 tint: ok ? DS.Palette.orange : DS.Palette.red)
                }
            }
        case .summarize(let text):
            ask("Summarize this in three short bullet points, then one line on what matters most:\n\n\(text.prefix(6000))")
        case .translate(let text):
            ask("Translate this into natural English. Reply with only the translation:\n\n\(text.prefix(4000))")
        case .reply(let text):
            ask("Draft a short, warm reply I could send to this message. Reply with only the draft:\n\n\(text.prefix(4000))")
        case .learn(let text):
            LearnStore.shared.make(from: text, title: Self.snippet(text).components(separatedBy: " ").prefix(6).joined(separator: " "), url: nil)
        case .tasks(let text):
            Task { @MainActor in
                var items: [String] = []
                if let notes = await Mind.shared.meetingNotes(String(text.prefix(9000)), title: "copied text") { items = notes.actions }
                if items.isEmpty { items = MeetingCompanion.actionItems(from: [text]) }
                guard !items.isEmpty else {
                    IslandManager.shared.confirm("checkmark.circle", "No tasks in it", tint: DS.Ink.secondary)
                    return
                }
                PlanStore.shared.carry(items, from: "From something you copied")
                IslandManager.shared.confirm("checkmark.circle.fill", items.count == 1 ? "1 task for your next plan" : "\(items.count) tasks for your next plan",
                                             tint: PlanView.morning)
            }
        }
    }

    /// Opens Flow with the question — its answer streams into the conversation, ready to copy.
    private func ask(_ prompt: String) {
        IslandManager.shared.primary?.model.openBrain()
        BrainAgent.shared.send(prompt)
    }

    #if DEBUG
    func debugShow(_ item: LensItem) { show(item) }
    #endif
}

/// The lens in the notch: what was copied (or dropped), and the next steps.
struct LensCard: View {
    var model: IslandModel
    let item: LensItem

    var body: some View {
        Instrument(notch: model.notch, width: model.alertSize.width, height: 72) {
            HStack(spacing: 12) {
                FlowSeal(size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(text: item.source, dot: nil, tint: BrainStyle.tint)
                    Text(item.snippet).font(DS.Kit.body).foregroundStyle(DS.Ink.primary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The next steps keep their whole names; the snippet gives way.
                ForEach(item.actions.prefix(2)) { action in
                    FlowOptionButton(title: action.title, prominent: action == item.actions.first) {
                        model.dismissAlert()
                        LensModel.shared.perform(action)
                    }
                    .fixedSize()
                }
                Ghost(symbol: "xmark", label: "Dismiss", size: 10, tint: DS.Ink.tertiary, hit: 24) { model.dismissAlert() }
            }
        }
    }
}
