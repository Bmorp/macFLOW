import SwiftUI

/// The small words beside a task: when, how long, which project. Nothing else.
enum TaskRowText {
    enum Tone { case plain, late }
    struct Part: Hashable {
        var text: String
        var tone: Tone = .plain
    }

    static func meta(_ t: FlowTask, list: TaskList, now: Date, calendar cal: Calendar = .current) -> [Part] {
        var out: [Part] = []
        let today = cal.startOfDay(for: now)
        if let s = t.scheduled, FlowTask.hasTime(s, calendar: cal), list != .someday {
            // In Upcoming the day is the section's; a time is all a row needs.
            out.append(Part(text: list == .upcoming || cal.isDate(s, inSameDayAs: now) ? TaskFormat.time(s) : TaskFormat.when(s, now: now, calendar: cal)))
        }
        if let due = t.due {
            if t.isOverdue(at: now, calendar: cal) {
                out.append(Part(text: "Due " + TaskFormat.day(due, now: now, calendar: cal), tone: .late))
            } else if cal.startOfDay(for: due) == today {
                out.append(Part(text: FlowTask.hasTime(due, calendar: cal) ? "Due " + TaskFormat.time(due) : "Due today"))
            } else if t.scheduled != nil || list != .upcoming {
                out.append(Part(text: "Due " + TaskFormat.day(due, now: now, calendar: cal)))
            } else {
                // In Upcoming the section says which day; the row says it's a deadline.
                out.append(Part(text: FlowTask.hasTime(due, calendar: cal) ? "Due " + TaskFormat.time(due) : "Due"))
            }
        }
        if let r = t.repeats { out.append(Part(text: short(r))) }
        if let e = t.estimate { out.append(Part(text: TaskFormat.length(e))) }
        if let p = t.project { out.append(Part(text: p)) }
        return out
    }

    static func short(_ r: RepeatRule) -> String {
        switch r {
        case .daily: "Daily"
        case .weekdays: "Weekdays"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        case .yearly: "Yearly"
        }
    }

    /// The whole row, read aloud: "Review deck, high priority, 3:00 PM, 45 minutes, launch".
    static func spoken(_ t: FlowTask, list: TaskList, now: Date) -> String {
        var parts = [t.title]
        if t.priority != .none { parts.append("\(["", "low", "medium", "high"][t.priority.rawValue]) priority") }
        let length = t.estimate.map(TaskFormat.length)
        for p in meta(t, list: list, now: now) {
            if p.text == length, let e = t.estimate {
                let f = DateComponentsFormatter()
                f.allowedUnits = [.hour, .minute]
                f.unitsStyle = .full
                parts.append(f.string(from: e * 60) ?? p.text)
            } else {
                parts.append(p.text)
            }
        }
        return parts.joined(separator: ", ")
    }
}

/// The circle you click to finish a task. Finishing fills it from the centre on a spring, as Reminders does.
struct CompletionCircle: View {
    let done: Bool
    /// In focus right now: the ring takes the accent.
    var active = false
    var size: CGFloat = 17
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(done || active ? TaskStyle.tint : Color.white.opacity(hover ? 0.62 : 0.34), lineWidth: 1.3)
                // Grows from nothing: no fades inside the island.
                Circle()
                    .fill(TaskStyle.tint)
                    .scaleEffect(done ? 1 : 0.001)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
                    .scaleEffect(done ? 1 : 0.001)
            }
            .frame(width: size, height: size)
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .accessibilityHidden(true)      // the row speaks for it, with a Complete action
    }
}

/// One task: the circle, its title, and a little about when and how long.
struct TaskRow: View {
    let task: FlowTask
    let list: TaskList
    let selected: Bool
    var editing = false
    @ObservedObject var model: TasksModel
    @ObservedObject var active: ActiveTask
    var focus: FocusState<TasksModel.Field?>.Binding
    @Environment(\.islandShowing) private var showing
    @State private var hover = false

    static let height: CGFloat = 32

    var body: some View {
        let now = Date()
        HStack(spacing: 6) {
            CompletionCircle(done: task.isDone, active: active.task?.id == task.id) { model.toggle(task.id) }
            if editing {
                TextField("", text: $model.editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.Ink.primary)
                    .focused(focus, equals: .edit)
                    .onSubmit { model.commitEdit() }
            } else {
                HStack(spacing: 5) {
                    if task.priority != .none {
                        Text(TaskFormat.priorityMarks(task.priority))
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(TaskStyle.tint)
                    }
                    Text(task.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(task.isDone ? DS.Ink.secondary : DS.Ink.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 10)
                meta(now: now)
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 10)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(selected ? 0.09 : hover ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onHover { h in hover = h }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TaskRowText.spoken(task, list: list, now: now))
        .accessibilityValue(task.isDone ? "Done" : active.task?.id == task.id ? "In focus" : "")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: task.isDone ? "Mark Not Done" : "Complete") { model.toggle(task.id) }
        .accessibilityAction(named: "Edit") { model.beginEdit(task.id) }
        .accessibilityAction(named: "Start Focus") { model.startFocus(task.id) }
        .accessibilityAction(named: "Move Up") { model.selection = task.id; model.reorder(-1) }
        .accessibilityAction(named: "Move Down") { model.selection = task.id; model.reorder(1) }
        .accessibilityAction(named: "Delete") { model.delete(task.id) }
    }

    @ViewBuilder private func meta(now: Date) -> some View {
        HStack(spacing: 0) {
            if active.task?.id == task.id, let since = active.since {
                // In focus: its time, ticking only while the island shows it.
                TimelineView(ElapsedSchedule(since: since, showing: showing)) { ctx in
                    Text("Focusing · " + TaskFormat.length(max(1, active.elapsed(at: ctx.date) / 60)))
                        .foregroundStyle(TaskStyle.tint)
                }
                if !parts(now).isEmpty { Text(" · ").foregroundStyle(DS.Ink.tertiary) }
            }
            ForEach(Array(parts(now).enumerated()), id: \.offset) { i, p in
                if i > 0 { Text(" · ").foregroundStyle(DS.Ink.tertiary) }
                Text(p.text).foregroundStyle(p.tone == .late ? DS.Palette.red : DS.Ink.secondary)
            }
        }
        .font(.system(size: 11, weight: .medium).monospacedDigit())
        .lineLimit(1)
        .fixedSize()
    }

    /// In focus, the clock replaces the planned time.
    private func parts(_ now: Date) -> [TaskRowText.Part] {
        var p = TaskRowText.meta(task, list: list, now: now)
        if active.task?.id == task.id, let s = task.scheduled, FlowTask.hasTime(s) { p.removeAll { $0.text == TaskFormat.time(s) } }
        return p
    }
}
