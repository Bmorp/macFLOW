import AppKit
import SwiftUI

/// The quick-add line, on its own so typing redraws the line and its preview, not the list.
@MainActor
final class QuickAddLine: ObservableObject {
    @Published var text = ""

    /// What it means so far.
    var parsed: TaskDraft? {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : TaskParser.parse(t)
    }
}

/// The Tasks place's state — which list, what's selected, what's being typed — and its keyboard. Kept apart from the
/// view so the island's key monitor can drive it, and so it survives the place being hidden and shown.
@MainActor
final class TasksModel: ObservableObject {
    static let shared = TasksModel()

    enum Field: Hashable { case quickAdd, edit }

    @Published var segment: TaskList = .today
    @Published var selection: UUID?
    @Published var editing: UUID?
    /// The title being edited. Not published: the field keeps its own text, and the list needn't redraw per key.
    var editText = ""
    let line = QuickAddLine()
    /// The quick-add line's text.
    var draft: String {
        get { line.text }
        set { line.text = newValue }
    }
    /// Which text field should have the keyboard; the view mirrors it into `@FocusState`.
    @Published var field: Field?
    /// The last deletion, offered back for a few seconds.
    @Published private(set) var undo: FlowTask?
    private var undoWork: DispatchWorkItem?
    private var cache: (key: String, sections: [TaskStore.Section])?

    private let injected: TaskStore?
    private var store: TaskStore { injected ?? TaskStore.shared }

    /// Tests hand in their own store; the app uses the shared one.
    init(store: TaskStore? = nil) { injected = store }

    /// The current list as shown, worked out once per change (not on every redraw, drag step or keystroke).
    var sections: [TaskStore.Section] {
        let key = "\(store.revision)|\(segment.rawValue)|\(DayPlan.key())"
        if let cache, cache.key == key { return cache.sections }
        let s = store.sections(segment)
        cache = (key, s)
        return s
    }

    /// The rows of the current list, top to bottom.
    var rows: [UUID] { sections.flatMap { $0.tasks.map(\.id) } }

    // MARK: Opening

    /// Opens Tasks, on a task if one's given.
    func show(_ id: UUID?) {
        if let id, let t = store.task(id: id) {
            segment = t.list()
            selection = id
        }
        IslandManager.shared.primary?.model.open(.tasks)
    }

    /// The place has just opened: a list to look at, or a line to type into when there's nothing yet.
    func opened() {
        let ids = rows
        if selection.map({ !ids.contains($0) }) ?? true { selection = ids.first }
        if ids.isEmpty { field = .quickAdd }
    }

    func select(_ list: TaskList) {
        guard list != segment else { return }
        withAnimation(Motion.morph) { segment = list }
        selection = rows.first
        if editing != nil { cancelEdit() }
    }

    // MARK: Doing things

    func move(_ delta: Int) {
        let ids = rows
        guard !ids.isEmpty else { return }
        let i = selection.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        selection = ids[min(max(0, i + delta), ids.count - 1)]
    }

    func toggle(_ id: UUID) {
        guard let t = store.task(id: id) else { return }
        if t.isOpen {
            HapticEngine.shared.play(.confirm, channel: .tasks)
            // Selection moves on before the finished row leaves.
            if selection == id, let i = rows.firstIndex(of: id) {
                let rest = rows.filter { $0 != id }
                selection = rest.isEmpty ? nil : rest[min(i, rest.count - 1)]
            }
        }
        withAnimation(Access.reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.62)) { store.toggle(id) }
    }

    func add() {
        let text = draft.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let d = TaskParser.parse(text)
        guard let t = withAnimation(Motion.morph, { store.add(d, typed: text, source: .typed, in: segment) }) else { return }
        HapticEngine.shared.play(.confirm, channel: .tasks)
        draft = ""
        // It may belong to another list ("tomorrow" typed in Today): show it there.
        let list = t.list()
        if list != segment { withAnimation(Motion.morph) { segment = list } }
        selection = t.id
    }

    func beginEdit(_ id: UUID? = nil) {
        guard let id = id ?? selection, let t = store.task(id: id) else { return }
        selection = id
        editing = id
        editText = t.title
        field = .edit
    }

    /// Return in an edit: the words are read again, so "tomorrow 3pm" typed onto a title moves the task.
    func commitEdit() {
        guard let id = editing else { return }
        let text = editText.trimmingCharacters(in: .whitespaces)
        editing = nil
        field = nil
        guard !text.isEmpty, let t = store.task(id: id), text != t.title else { return }
        let d = TaskParser.parse(text)
        store.update(id) {
            $0.title = d.title.isEmpty ? text : d.title
            if let s = d.scheduled { $0.scheduled = s; $0.someday = false }
            if let due = d.due { $0.due = due }
            if let e = d.estimate { $0.estimate = e; $0.estimateIsUser = true }
            if let p = d.project { $0.project = p }
            if d.priority != .none { $0.priority = d.priority }
            if let r = d.repeats { $0.repeats = r }
            if d.someday { $0.someday = true; $0.scheduled = nil }
        }
    }

    func cancelEdit() {
        editing = nil
        field = nil
    }

    func delete(_ id: UUID? = nil) {
        guard let id = id ?? selection else { return }
        let ids = rows
        let i = ids.firstIndex(of: id) ?? 0
        guard let gone = withAnimation(Motion.morph, { store.delete(id) }) else { return }
        let rest = ids.filter { $0 != id }
        selection = rest.isEmpty ? nil : rest[min(i, rest.count - 1)]
        undo = gone
        undoWork?.cancel()
        let w = DispatchWorkItem { [weak self] in withAnimation(Motion.morph) { self?.undo = nil } }
        undoWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: w)
    }

    func undoDelete() {
        guard let t = undo else { return }
        undoWork?.cancel()
        withAnimation(Motion.morph) {
            store.restore(t)
            undo = nil
        }
        segment = t.list()
        selection = t.id
    }

    /// ⌘↑ / ⌘↓.
    func reorder(_ delta: Int) {
        guard let id = selection else { return }
        let section = sections.first { $0.tasks.contains { $0.id == id } }
        guard let ids = section?.tasks.map(\.id), let i = ids.firstIndex(of: id) else { return }
        let target = i + delta
        guard target >= 0, target < ids.count else { return }
        withAnimation(Motion.morph) { store.move(id, to: target, in: ids) }
    }

    func startFocus(_ id: UUID? = nil) {
        guard let id = id ?? selection else { return }
        store.startFocus(id)
        IslandManager.shared.primary?.model.collapse()
    }

    func schedule(_ id: UUID, _ when: TaskList, tomorrow: Bool = false) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        withAnimation(Motion.morph) {
            switch when {
            case .today: store.schedule(id, on: tomorrow ? cal.date(byAdding: .day, value: 1, to: today) : today)
            case .upcoming: store.schedule(id, on: cal.date(byAdding: .day, value: 1, to: today))
            case .someday: store.parkSomeday(id)
            }
        }
    }

    // MARK: Keyboard

    /// Keys while Tasks is open. `typing` is whether a text field has the keyboard. Returns whether it was used.
    func handle(_ e: NSEvent, typing: Bool) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let key = e.keyCode
        if cmd, e.charactersIgnoringModifiers?.lowercased() == "n" {
            field = .quickAdd
            return true
        }
        if cmd, e.charactersIgnoringModifiers?.lowercased() == "z", !typing, undo != nil {
            undoDelete()
            return true
        }
        if typing {
            switch key {
            case 36, 76:                                                      // Return
                if field == .edit { commitEdit() } else { add() }
                return true
            case 53:                                                          // Esc
                if field == .edit { cancelEdit() } else if !draft.isEmpty { draft = "" } else { field = nil }
                return true
            case 125 where field == .quickAdd:                                // ↓ from the line into the list
                field = nil
                if selection == nil { selection = rows.first }
                return true
            default:
                return false
            }
        }
        switch key {
        case 126 where cmd: reorder(-1); return true                         // ⌘↑
        case 125 where cmd: reorder(1); return true                          // ⌘↓
        case 126: move(-1); return true
        case 125: move(1); return true
        case 123: step(-1); return true                                      // ← →: the lists
        case 124: step(1); return true
        case 49: if let id = selection { toggle(id) }; return true           // Space
        case 36 where cmd, 76 where cmd: startFocus(); return true          // ⌘↩
        case 36, 76: beginEdit(); return true
        case 51, 117: delete(); return true                                  // ⌫, ⌦
        default:
            if cmd, let ch = e.charactersIgnoringModifiers, let n = Int(ch), (1...3).contains(n) {
                select(TaskList.allCases[n - 1])
                return true
            }
            // Typing anywhere starts a task.
            guard !cmd, !flags.contains(.control), let text = e.characters, !text.isEmpty,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) else { return false }
            draft += text
            field = .quickAdd
            return true
        }
    }

    private func step(_ delta: Int) {
        let all = TaskList.allCases
        guard let i = all.firstIndex(of: segment) else { return }
        select(all[(i + delta + all.count) % all.count])
    }
}
