import Foundation
import CoreGraphics
import Combine

// Mac Flow Pro (9.0) contracts.
//
// The 9.0 work is built in parallel streams: Island Engine, Haptics, Prism, Flow Tasks and the Brain. They meet
// only through the types in this file, so each stream compiles on its own. Change these only on the `pro`
// branch, never inside a stream.

// MARK: - Haptics

/// What a haptic means. `HapticEngine` (Core/HapticEngine.swift) maps each cue to one of the three
/// patterns a Mac trackpad can play, and decides whether and when it fires.
enum HapticCue: Sendable, Hashable {
    /// One step of something continuous: a moment in Rewind, a tick on a slider.
    case detent
    /// A step that matters more than its neighbours: an hour mark, a change of app.
    case landmark
    /// A range reached its end.
    case edge
    /// A gesture crossed the point where letting go completes it.
    case commit
    /// The island settled where the pointer or finger left it.
    case land
    /// A discrete action finished: dropped, copied, done.
    case confirm
    /// A stepped value changed level: hold-to-talk engaged, a priority changed.
    case level
}

/// When a haptic fires relative to what's on screen.
enum HapticTiming: Sendable, Hashable {
    /// With the frame that shows the change (`.drawCompleted`). The default.
    case withFrame
    /// Right away, for a response to a press.
    case now
}

/// Each gesture gets its own channel, so one gesture's throttle never swallows another's range end.
struct HapticChannel: Hashable, Sendable {
    let name: String
    init(_ name: String) { self.name = name }

    static let ui = HapticChannel("ui")
    static let island = HapticChannel("island")
    static let rewind = HapticChannel("rewind")
    static let seek = HapticChannel("seek")
    static let slider = HapticChannel("slider")
    static let standBy = HapticChannel("standby")
    static let tasks = HapticChannel("tasks")
    static let drop = HapticChannel("drop")
    static let talk = HapticChannel("talk")
    static let widgets = HapticChannel("widgets")
}

// MARK: - Tasks

enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case open, active, done, dropped
}

enum TaskPriority: Int, Codable, Sendable, Comparable, CaseIterable {
    case none = 0, low, medium, high
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// Where a task came from, which the Brain uses as a feature.
enum TaskSource: String, Codable, Sendable {
    case typed, voice, search, lens, meeting, plan, reminders, flow, drop
}

/// One task as the rest of the app sees it. Flow Tasks owns the store; everyone else reads snapshots.
struct TaskSnapshot: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var title: String
    var notes: String = ""
    var project: String?
    /// When it has to be done by.
    var due: Date?
    /// When it's planned to be worked on.
    var scheduled: Date?
    /// The estimate, in minutes: the user's if they gave one, otherwise the Brain's.
    var estimate: Double?
    var priority: TaskPriority = .none
    var status: TaskStatus = .open
    var source: TaskSource = .typed
    /// Focused time spent on it so far, in seconds.
    var actual: TimeInterval = 0
    var created: Date
    var completed: Date?
}

/// Everything that happens to a task, published by Flow Tasks the moment it happens.
enum TaskEvent: Sendable {
    case added(TaskSnapshot)
    case updated(TaskSnapshot)
    /// Work on it began (a focus block started for it, or it was marked active).
    case started(TaskSnapshot)
    /// Work on it stopped; `focused` is the time spent in this stretch.
    case paused(TaskSnapshot, focused: TimeInterval)
    case completed(TaskSnapshot)
    case reopened(TaskSnapshot)
    case deleted(UUID)
}

@MainActor
enum TaskEvents {
    static let stream = PassthroughSubject<TaskEvent, Never>()
    static func send(_ event: TaskEvent) { stream.send(event) }
}

/// The Brain's estimate for a task.
struct TaskEstimate: Hashable, Sendable {
    var minutes: Double
    /// A rough 80% range.
    var low: Double
    var high: Double
    /// 0…1.
    var confidence: Double
    /// One line the UI can show: "Like your last 4 decks, about 45 min".
    var why: String
}

/// What the Brain offers Tasks. The Brain registers itself as `TaskLinks.advisor`.
@MainActor
protocol TaskAdvisor: AnyObject {
    func estimate(for task: TaskSnapshot) -> TaskEstimate?
    /// Learned importance, 0…1, used to rank Today and the morning plan.
    func importance(of task: TaskSnapshot, at date: Date) -> Double
}

/// What Tasks lets the Brain read and change. Flow Tasks registers itself as `TaskLinks.ledger`.
@MainActor
protocol TaskLedger: AnyObject {
    /// Open and active tasks.
    func openTasks() -> [TaskSnapshot]
    func task(_ id: UUID) -> TaskSnapshot?
    func complete(_ id: UUID)
    /// Add a task from plain words ("review deck tomorrow 3pm 45m"), parsed the same way as typed capture.
    @discardableResult func capture(_ text: String, source: TaskSource) -> TaskSnapshot?
    /// Store the Brain's estimate on a task the user hasn't estimated.
    func suggestEstimate(_ id: UUID, minutes: Double)
}

@MainActor
enum TaskLinks {
    static weak var advisor: TaskAdvisor?
    static weak var ledger: TaskLedger?
}

// MARK: - Prism

/// How a Prism surface looks: content seen through vertical fluted glass.
/// `View.prism(_:)` (DesignSystem/Prism.swift) applies it.
struct PrismStyle: Hashable, Sendable {
    /// Width of one glass strip, in points.
    var pitch: CGFloat
    /// How strongly each strip bends what's behind it, 0…1.
    var lens: CGFloat
    /// Magnification across a strip; negative mirrors it.
    var magnify: CGFloat
    /// How far behind the glass the content sits, in points.
    var depth: CGFloat
    /// Chromatic dispersion at strip edges, 0…1.
    var disperse: CGFloat
    /// Ridge highlight, 0…1.
    var specular: CGFloat
    /// Share of strips that carry a coloured spark, 0…1. Rationed: a hero moment, not decoration.
    var sparks: CGFloat
    var seed: UInt32 = 0

    static let island = PrismStyle(pitch: 2.5, lens: 0.6, magnify: 1.4, depth: 6, disperse: 0.25, specular: 0.35, sparks: 0)
    static let standBy = PrismStyle(pitch: 5, lens: 0.8, magnify: 1.8, depth: 14, disperse: 0.5, specular: 0.5, sparks: 0.012)
    static let nowPlaying = PrismStyle(pitch: 4, lens: 0.7, magnify: 1.6, depth: 10, disperse: 0.35, specular: 0.4, sparks: 0)
    static let flow = PrismStyle(pitch: 3, lens: 0.65, magnify: 1.5, depth: 8, disperse: 0.4, specular: 0.4, sparks: 0.02)
}
