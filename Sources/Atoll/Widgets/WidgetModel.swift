import SwiftUI
import AppKit

enum WidgetFamily: String, Codable, CaseIterable, Identifiable {
    case small, medium, large
    var id: String { rawValue }

    /// Mac desktop widget sizes.
    var size: CGSize {
        switch self {
        case .small: CGSize(width: 170, height: 170)
        case .medium: CGSize(width: 364, height: 170)
        case .large: CGSize(width: 364, height: 382)
        }
    }

    var label: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

enum WidgetKind: String, Codable, CaseIterable, Identifiable {
    case nowPlaying, upNext, weather, worldClock, batteries, timer, reminders, system, shortcuts, shelf
    var id: String { rawValue }

    var title: String {
        switch self {
        case .nowPlaying: "Now Playing"
        case .upNext: "Up Next"
        case .weather: "Weather"
        case .worldClock: "World Clock"
        case .batteries: "Batteries"
        case .timer: "Focus Timer"
        case .reminders: "Reminders"
        case .system: "System"
        case .shortcuts: "Shortcuts"
        case .shelf: "Shelf"
        }
    }

    /// One description per widget, verb first, sentence case (`widgets.md › Previews`).
    var summary: String {
        switch self {
        case .nowPlaying: "Control what’s playing and see the artwork."
        case .upNext: "Keep track of your next meeting and join with one click."
        case .weather: "See current conditions and the next few hours."
        case .worldClock: "Check the time where the people you work with are."
        case .batteries: "Watch the charge of your Mac and AirPods."
        case .timer: "Start a focus session and see how much time is left."
        case .reminders: "Check off today’s reminders."
        case .system: "Keep an eye on processor, memory and disk use."
        case .shortcuts: "Run your favourite shortcuts."
        case .shelf: "Keep files handy and drag them out when you need them."
        }
    }

    var symbol: String {
        switch self {
        case .nowPlaying: "play.circle.fill"
        case .upNext: "calendar"
        case .weather: "cloud.sun.fill"
        case .worldClock: "clock.fill"
        case .batteries: "battery.75percent"
        case .timer: "timer"
        case .reminders: "checklist"
        case .system: "gauge.with.dots.needle.67percent"
        case .shortcuts: "square.stack.3d.up.fill"
        case .shelf: "tray.full.fill"
        }
    }

    var families: [WidgetFamily] {
        switch self {
        case .nowPlaying, .weather, .worldClock, .batteries, .shortcuts: [.small, .medium]
        case .upNext: [.small, .medium, .large]
        case .timer, .system: [.small]
        case .reminders: [.medium, .large]
        case .shelf: [.medium]
        }
    }
}

struct WidgetInstance: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: WidgetKind
    var family: WidgetFamily
    /// Top-left offset from the screen's visible frame top-left, in points.
    var offset: CGPoint
    var screenID: UInt32
}

/// Layout, persistence and editing state for desktop widgets.
@MainActor
final class WidgetStore: ObservableObject {
    static let shared = WidgetStore()

    @Published private(set) var instances: [WidgetInstance] = []
    @Published var editing = false
    /// Full colour while you're on the desktop; vibrant monochrome while you work in an app.
    @Published private(set) var desktopFocused = true

    static let grid: CGFloat = 16
    static let gap: CGFloat = 16
    static let margin: CGFloat = 32
    private let fileName = "widgets.json"

    init() {
        if let saved = Storage.load([WidgetInstance].self, from: fileName) {
            instances = saved
        } else {
            instances = defaultLayout()
            save()
        }
        desktopFocused = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let focused = app?.bundleIdentifier == "com.apple.finder"
            MainActor.assumeIsolated {
                guard let self, self.desktopFocused != focused else { return }
                withAnimation(.smooth(duration: 0.5)) { self.desktopFocused = focused }
            }
        }
    }

    // MARK: - Screens

    static func screen(for id: UInt32) -> NSScreen {
        NSScreen.screens.first { $0.displayID == id } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static var primaryScreen: NSScreen { NSScreen.screens.first(where: \.hasNotch) ?? NSScreen.main ?? NSScreen.screens[0] }

    /// Cocoa frame (bottom-left origin) for an instance.
    func frame(for w: WidgetInstance) -> NSRect {
        let vf = Self.screen(for: w.screenID).visibleFrame
        let s = w.family.size
        return NSRect(x: vf.minX + w.offset.x, y: vf.maxY - w.offset.y - s.height, width: s.width, height: s.height)
    }

    private func rect(_ offset: CGPoint, _ size: CGSize) -> CGRect { CGRect(origin: offset, size: size) }

    private func others(on screen: UInt32, excluding id: UUID?) -> [CGRect] {
        instances.filter { $0.id != id && $0.screenID == screen }.map { rect($0.offset, $0.family.size) }
    }

    /// Widgets keep at least one gap between them.
    private func collides(_ r: CGRect, screen: UInt32, excluding id: UUID?) -> Bool {
        others(on: screen, excluding: id).contains { $0.insetBy(dx: -(Self.gap - 0.5), dy: -(Self.gap - 0.5)).intersects(r) }
    }

    private func bounds(_ screen: UInt32, _ size: CGSize) -> (x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) {
        let vf = Self.screen(for: screen).visibleFrame
        return (Self.margin...max(Self.margin, vf.width - Self.margin - size.width),
                Self.margin / 2...max(Self.margin / 2, vf.height - Self.margin / 2 - size.height))
    }

    /// Pulls a position onto nearby edges — other widgets (flush or one gap apart) and the screen margins.
    func aligned(_ p: CGPoint, size: CGSize, screen: UInt32, excluding id: UUID?, threshold: CGFloat = 10) -> (point: CGPoint, x: Bool, y: Bool) {
        let b = bounds(screen, size)
        var xs: [CGFloat] = [b.x.lowerBound, b.x.upperBound]
        var ys: [CGFloat] = [b.y.lowerBound, b.y.upperBound]
        for r in others(on: screen, excluding: id) {
            xs += [r.minX, r.maxX - size.width, r.maxX + Self.gap, r.minX - Self.gap - size.width]
            ys += [r.minY, r.maxY - size.height, r.maxY + Self.gap, r.minY - Self.gap - size.height]
        }
        var out = p
        let bx = xs.min { abs($0 - p.x) < abs($1 - p.x) }
        let by = ys.min { abs($0 - p.y) < abs($1 - p.y) }
        var ax = false, ay = false
        if let bx, abs(bx - p.x) <= threshold { out.x = bx; ax = true }
        if let by, abs(by - p.y) <= threshold { out.y = by; ay = true }
        return (out, ax, ay)
    }

    /// Where a widget dropped near `desired` actually lands: aligned to its neighbours when close,
    /// otherwise on the 16-pt grid — and never overlapping or off screen.
    func placement(near desired: CGPoint, size: CGSize, screen: UInt32, excluding id: UUID?) -> CGPoint {
        let b = bounds(screen, size)
        let a = aligned(desired, size: size, screen: screen, excluding: id)
        var p = a.point
        if !a.x { p.x = (p.x / Self.grid).rounded() * Self.grid }
        if !a.y { p.y = (p.y / Self.grid).rounded() * Self.grid }
        p.x = min(max(p.x, b.x.lowerBound), b.x.upperBound)
        p.y = min(max(p.y, b.y.lowerBound), b.y.upperBound)
        if !collides(rect(p, size), screen: screen, excluding: id) { return p }

        // Candidates: tidy spots next to each neighbour, then the whole grid.
        var candidates: [CGPoint] = []
        for r in others(on: screen, excluding: id) {
            candidates += [CGPoint(x: r.maxX + Self.gap, y: r.minY), CGPoint(x: r.minX - Self.gap - size.width, y: r.minY),
                           CGPoint(x: r.minX, y: r.maxY + Self.gap), CGPoint(x: r.minX, y: r.minY - Self.gap - size.height)]
        }
        var y = b.y.lowerBound
        while y <= b.y.upperBound {
            var x = b.x.lowerBound
            while x <= b.x.upperBound {
                candidates.append(CGPoint(x: x, y: y))
                x += Self.grid
            }
            y += Self.grid
        }
        let free = candidates.filter { b.x.contains($0.x) && b.y.contains($0.y) && !collides(rect($0, size), screen: screen, excluding: id) }
        return free.min { hypot($0.x - p.x, $0.y - p.y) < hypot($1.x - p.x, $1.y - p.y) } ?? p
    }

    /// Offset (top-left, relative to the visible frame) for a Cocoa origin on a screen.
    func offset(forCocoaOrigin origin: CGPoint, size: CGSize, on screen: NSScreen) -> CGPoint {
        let vf = screen.visibleFrame
        return CGPoint(x: origin.x - vf.minX, y: vf.maxY - (origin.y + size.height))
    }

    func cocoaOrigin(forOffset offset: CGPoint, size: CGSize, on screen: NSScreen) -> CGPoint {
        let vf = screen.visibleFrame
        return CGPoint(x: vf.minX + offset.x, y: vf.maxY - offset.y - size.height)
    }

    // MARK: - Editing

    func instance(_ id: UUID) -> WidgetInstance? { instances.first { $0.id == id } }

    @discardableResult
    func add(_ kind: WidgetKind, family: WidgetFamily) -> WidgetInstance {
        let screen = Self.primaryScreen.displayID
        let offset = placement(near: CGPoint(x: Self.margin, y: Self.margin / 2), size: family.size, screen: screen, excluding: nil)
        let w = WidgetInstance(kind: kind, family: family, offset: offset, screenID: screen)
        withAnimation(Motion.duo) { instances.append(w) }
        save()
        return w
    }

    func remove(_ id: UUID) {
        withAnimation(Motion.duo) { instances.removeAll { $0.id == id } }
        save()
    }

    func resize(_ id: UUID, to family: WidgetFamily) {
        guard let i = instances.firstIndex(where: { $0.id == id }) else { return }
        let w = instances[i]
        instances[i].family = family
        instances[i].offset = placement(near: w.offset, size: family.size, screen: w.screenID, excluding: id)
        save()
    }

    /// Commits a drag: snaps to the grid and the nearest free slot on whichever screen it landed.
    func move(_ id: UUID, toCocoaOrigin origin: CGPoint) -> WidgetInstance? {
        guard let i = instances.firstIndex(where: { $0.id == id }) else { return nil }
        let size = instances[i].family.size
        let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? Self.screen(for: instances[i].screenID)
        let desired = offset(forCocoaOrigin: origin, size: size, on: screen)
        instances[i].screenID = screen.displayID
        instances[i].offset = placement(near: desired, size: size, screen: screen.displayID, excluding: id)
        save()
        return instances[i]
    }

    private func defaultLayout() -> [WidgetInstance] {
        let s = Self.primaryScreen.displayID
        let m = Self.margin, top = Self.margin / 2, g = Self.gap
        return [
            WidgetInstance(kind: .worldClock, family: .small, offset: CGPoint(x: m, y: top), screenID: s),
            WidgetInstance(kind: .weather, family: .small, offset: CGPoint(x: m + 170 + g, y: top), screenID: s),
            WidgetInstance(kind: .upNext, family: .medium, offset: CGPoint(x: m, y: top + 170 + g), screenID: s),
            WidgetInstance(kind: .nowPlaying, family: .medium, offset: CGPoint(x: m, y: top + 2 * (170 + g)), screenID: s),
            WidgetInstance(kind: .batteries, family: .small, offset: CGPoint(x: m, y: top + 3 * (170 + g)), screenID: s),
            WidgetInstance(kind: .system, family: .small, offset: CGPoint(x: m + 170 + g, y: top + 3 * (170 + g)), screenID: s),
        ]
    }

    func save() { Storage.save(instances, to: fileName) }

    #if DEBUG
    func debugReplace(_ list: [WidgetInstance]) { instances = list }
    #endif
}
