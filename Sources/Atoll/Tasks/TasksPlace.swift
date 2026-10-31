import SwiftUI

/// The island's Tasks place: Today, Upcoming and Someday, a line at the top to add to them, and the tasks themselves —
/// a circle, a title, and a little about when and how long. Keyboard first: ⌘N adds, ↑↓ move, Space completes, Return
/// edits, ⌫ deletes (⌘Z brings it back), ⌘↑↓ reorder, ⌘↩ starts a focus block, ← → change list.
struct TasksPlace: View {
    static let height: CGFloat = 320
    var model: IslandModel
    @ObservedObject private var store = TaskStore.shared
    @ObservedObject private var tasks = TasksModel.shared
    @ObservedObject private var sync = ReminderSync.shared
    @Environment(\.islandShowing) private var showing
    @FocusState private var focus: TasksModel.Field?
    @State private var drag: Drag?

    /// A row being dragged to a new place: where it started, where it would land, how far the pointer has moved.
    private struct Drag: Equatable {
        var id: UUID
        var section: String
        var start: Int
        var target: Int
        var offset: CGFloat
    }

    init(model: IslandModel) { self.model = model }

    private var inset: CGFloat { IslandModel.expandedFlare + DS.Island.rowLeading + 4 }
    private static let pitch = TaskRow.height + 2

    var body: some View {
        let size = model.expandedSize(.tasks)
        let sections = tasks.sections
        VStack(spacing: 0) {
            header
                .frame(height: model.notch.height)
                .padding(.horizontal, inset)
            QuickAddField(line: tasks.line, list: tasks.segment, typing: focus == .quickAdd, focus: $focus) { tasks.add() }
                .padding(.horizontal, inset - 10)
                .padding(.top, 8)
            list(sections)
                .padding(.horizontal, inset - 10)
                .padding(.top, 6)
                .frame(maxHeight: .infinity, alignment: .top)
            footer
                .padding(.horizontal, inset)
                .frame(height: 30)
                .padding(.bottom, 8)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .onChange(of: showing, initial: true) { _, on in if on { opened() } else { closed() } }
        .onChange(of: tasks.field) { _, f in
            if focus != f { focus = f }
            if f != nil { cursorToEnd() }
        }
        .onChange(of: focus) { _, f in if tasks.field != f { tasks.field = f } }
    }

    // MARK: Opening and closing

    private func opened() {
        guard model.mode == .expanded(.tasks), !RenderMode.snapshot else { return }
        tasks.opened()
        // The keyboard comes once the island has settled (taking focus wakes the input system: a short stall that would
        // land mid-morph).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            guard model.mode == .expanded(.tasks) else { return }
            model.panel?.makeKey()
            focus = tasks.field
        }
    }

    private func closed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
            guard !showing else { return }
            if tasks.editing != nil { tasks.commitEdit() }
            focus = nil
            tasks.field = nil
        }
    }

    /// A field that takes the keyboard selects all its text; typing carries on from the end instead.
    private func cursorToEnd() {
        DispatchQueue.main.async {
            guard let editor = model.panel?.firstResponder as? NSTextView else { return }
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        }
    }

    // MARK: Header (beside the notch)

    private var header: some View {
        HStack(spacing: 10) {
            Spacer(minLength: model.notch.width + 24)
            picker
            syncControl
        }
    }

    private var picker: some View {
        HStack(spacing: 2) {
            ForEach(TaskList.allCases) { l in
                Button { tasks.select(l) } label: {
                    Text(l.rawValue)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(tasks.segment == l ? Color.black : DS.Ink.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(Capsule().fill(tasks.segment == l ? Color.white : .clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(tasks.segment == l ? .isSelected : [])
                .help("\(l.rawValue) (⌘\((TaskList.allCases.firstIndex(of: l) ?? 0) + 1))")
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.08)))
    }

    /// Reminders sync: one glyph. Off, it offers to start; on, a menu to sync now, pick the list, or stop.
    @ViewBuilder private var syncControl: some View {
        switch sync.state {
        case .off:
            GlyphButton(symbol: "arrow.triangle.2.circlepath", label: "Sync with Reminders, to see tasks on iPhone and Apple Watch", size: 11,
                        tint: DS.Ink.tertiary, hit: 26) { sync.turnOn() }
        case .denied:
            GlyphButton(symbol: "exclamationmark.triangle", label: "Mac Flow can’t reach Reminders — allow it in Privacy & Security", size: 11,
                        tint: DS.Palette.orange, hit: 26) { RemindersService.shared.requestAccess() }
        default:
            Menu {
                Button("Sync Now") { sync.schedule(after: 0) }
                let lists = sync.lists
                if lists.count > 1 {
                    Picker("List", selection: Binding(get: { sync.listID ?? "" }, set: { sync.use(list: $0) })) {
                        ForEach(lists, id: \.id) { Text($0.title).tag($0.id) }
                    }
                }
                Divider()
                Button("Stop Syncing") { sync.turnOff() }
            } label: {
                Image(systemName: syncSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(syncTint)
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(syncHelp)
            .accessibilityLabel(syncHelp)
        }
    }

    private var syncSymbol: String {
        switch sync.state {
        case .syncing: "iphone.radiowaves.left.and.right"
        case .failed: "exclamationmark.triangle"
        default: "iphone"
        }
    }
    private var syncTint: Color { if case .failed = sync.state { return DS.Palette.orange }; return DS.Ink.secondary }
    private var syncHelp: String {
        switch sync.state {
        case .failed(let why): why
        case .syncing: "Syncing with Reminders…"
        default: "Synced with Reminders · \(sync.listName ?? ReminderSync.defaultListTitle) list"
        }
    }

    // MARK: The list

    @ViewBuilder private func list(_ sections: [TaskStore.Section]) -> some View {
        if sections.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: tasks.segment == .today && store.doneToday > 0 ? "checkmark.circle.fill" : "checklist")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(tasks.segment == .today && store.doneToday > 0 ? TaskStyle.tint : DS.Ink.tertiary)
                Text(emptyLine)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.Ink.secondary)
                Text("Type above, or press ⌘N")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.Ink.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.bottom, 18)
            .accessibilityElement(children: .combine)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(sections) { section in
                            if let title = section.title {
                                Text(title.uppercased())
                                    .font(DS.Kit.eyebrow)
                                    .tracking(DS.Kit.eyebrowTracking)
                                    .foregroundStyle(DS.Ink.tertiary)
                                    .padding(.leading, 36)
                                    .padding(.top, section.id == sections.first?.id ? 2 : 10)
                                    .padding(.bottom, 2)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            ForEach(Array(section.tasks.enumerated()), id: \.element.id) { i, t in
                                row(t, index: i, section: section)
                            }
                        }
                    }
                    .padding(.bottom, 16)
                }
                .scrollBounceBehavior(.basedOnSize)
                // The list runs on under the footer: let it go rather than cut it.
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.9), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .onChange(of: tasks.selection) { _, id in
                    guard let id, drag == nil else { return }
                    withAnimation(Motion.morph) { proxy.scrollTo(id) }
                }
            }
        }
    }

    private func row(_ t: FlowTask, index i: Int, section: TaskStore.Section) -> some View {
        let dragging = drag?.id == t.id
        return TaskRow(task: t, list: tasks.segment, selected: tasks.selection == t.id || dragging, editing: tasks.editing == t.id,
                       model: tasks, active: store.active, focus: $focus)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(dragging ? 0.06 : 0)))
            .scaleEffect(dragging ? 1.015 : 1)
            .offset(y: offset(for: t.id, index: i, section: section.id))
            .zIndex(dragging ? 1 : 0)
            .id(t.id)
            .onTapGesture { select(t.id) }
            .simultaneousGesture(TapGesture(count: 2).onEnded { tasks.beginEdit(t.id) })
            .gesture(reorder(t, index: i, section: section))
            .contextMenu {
                Button("Start Focus") { tasks.startFocus(t.id) }
                Button("Edit") { tasks.beginEdit(t.id) }
                Divider()
                Button("Today") { tasks.schedule(t.id, .today) }
                Button("Tomorrow") { tasks.schedule(t.id, .today, tomorrow: true) }
                Button("Someday") { tasks.schedule(t.id, .someday) }
                Divider()
                Button("Delete") { tasks.delete(t.id) }
            }
    }

    private func select(_ id: UUID) {
        if tasks.editing != nil, tasks.editing != id { tasks.commitEdit() }
        tasks.selection = id
        tasks.field = nil
        model.panel?.makeKey()
    }

    /// While a row is dragged it follows the pointer; the rows it passes step aside.
    private func offset(for id: UUID, index i: Int, section: String) -> CGFloat {
        guard let d = drag, d.section == section else { return 0 }
        if d.id == id { return d.offset }
        if d.start < d.target, i > d.start, i <= d.target { return -Self.pitch }
        if d.target < d.start, i >= d.target, i < d.start { return Self.pitch }
        return 0
    }

    private func reorder(_ t: FlowTask, index: Int, section: TaskStore.Section) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                if drag == nil {
                    guard tasks.editing == nil else { return }
                    drag = Drag(id: t.id, section: section.id, start: index, target: index, offset: 0)
                    tasks.selection = t.id
                }
                guard var d = drag, d.id == t.id else { return }
                d.offset = v.translation.height
                let target = max(0, min(section.tasks.count - 1, d.start + Int((d.offset / Self.pitch).rounded())))
                drag = d
                if target != d.target {
                    // A detent for each place passed, on the frame the rows move.
                    HapticEngine.shared.play(.detent, channel: .tasks)
                    withAnimation(Motion.morph) { drag?.target = target }
                }
            }
            .onEnded { _ in
                guard let d = drag else { return }
                let ids = section.tasks.map(\.id)
                withAnimation(Motion.morph) {
                    if d.target != d.start { store.move(d.id, to: d.target, in: ids) }
                    drag = nil
                }
            }
    }

    private var emptyLine: String {
        switch tasks.segment {
        case .today: store.doneToday > 0 ? "All done for today." : "Nothing for today."
        case .upcoming: "Nothing coming up."
        case .someday: "Nothing parked for some day."
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            if let gone = tasks.undo {
                Text("Deleted “\(gone.title)”")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.Ink.secondary)
                    .lineLimit(1)
                Button("Undo") { tasks.undoDelete() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(TaskStyle.tint)
                KeyCap(text: "⌘Z")
            } else if tasks.segment == .today, store.doneToday > 0 {
                Text("\(store.doneToday) done today")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(DS.Ink.tertiary)
            }
            Spacer(minLength: 8)
            if tasks.selection != nil, tasks.field == nil, tasks.undo == nil {
                hint("Space", "Done")
                hint("↩", "Edit")
                hint("⌘↩", "Focus")
            }
        }
    }

    private func hint(_ key: String, _ what: String) -> some View {
        HStack(spacing: 4) {
            KeyCap(text: key)
            Text(what).font(.system(size: 10.5, weight: .medium)).foregroundStyle(DS.Ink.tertiary)
        }
        .accessibilityHidden(true)
    }
}

/// The line at the top: type a task the way you'd say it; what it understood shows beside it before you press Return.
private struct QuickAddField: View {
    @ObservedObject var line: QuickAddLine
    let list: TaskList
    let typing: Bool
    var focus: FocusState<TasksModel.Field?>.Binding
    let onSubmit: () -> Void

    private var prompt: String {
        switch list {
        case .today: "Add to Today, like “review deck 3pm 45m #launch”"
        case .upcoming: "Add a task, like “call Sam friday 4pm”"
        case .someday: "Park an idea for some day"
        }
    }

    var body: some View {
        let parsed = line.parsed
        return HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(typing ? TaskStyle.tint : DS.Ink.tertiary)
                .frame(width: 28, height: 28)
            TextField("", text: $line.text, prompt: Text(prompt).foregroundColor(DS.Ink.tertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DS.Ink.primary)
                .focused(focus, equals: .quickAdd)
                .onSubmit(onSubmit)
                .accessibilityLabel("New task")
            if let parsed, parsed.hasDetails {
                // What it understood, before you press Return.
                HStack(spacing: 4) {
                    ForEach(TaskFormat.parts(of: parsed), id: \.self) { part in
                        Text(part)
                            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                            .foregroundStyle(TaskStyle.tint)
                            .padding(.horizontal, 7)
                            .frame(height: 20)
                            .background(Capsule().fill(TaskStyle.tint.opacity(0.16)))
                            .fixedSize()
                    }
                }
                .transition(.scale(scale: 0.9, anchor: .trailing))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Understood: " + TaskFormat.parts(of: parsed).joined(separator: ", "))
            } else if !typing, line.text.isEmpty {
                KeyCap(text: "⌘N")
            }
        }
        .animation(Motion.morph, value: parsed?.hasDetails ?? false)
        .padding(.leading, 2)
        .padding(.trailing, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.white.opacity(typing ? 0.09 : 0.06)))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Color.white.opacity(typing ? 0.18 : 0.05), lineWidth: 0.5))
    }
}
