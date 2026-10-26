import SwiftUI
import Carbon.HIToolbox

enum DisplayMode: Int, CaseIterable, Identifiable {
    case notchScreen, mainScreen, allScreens
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .notchScreen: "Built-in Display"
        case .mainScreen: "Main Display"
        case .allScreens: "All Displays"
        }
    }
}

enum TemperatureUnit: Int, CaseIterable, Identifiable {
    case automatic, celsius, fahrenheit
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .celsius: "Celsius"
        case .fahrenheit: "Fahrenheit"
        }
    }
    var usesFahrenheit: Bool {
        switch self {
        case .automatic: Locale.current.measurementSystem == .us
        case .celsius: false
        case .fahrenheit: true
        }
    }
}

enum HotKeyChoice: Int, CaseIterable, Identifiable {
    case optionSpace, controlOptionSpace, commandShiftSpace, optionBacktick, disabled
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .optionSpace: "⌥ Space"
        case .controlOptionSpace: "⌃⌥ Space"
        case .commandShiftSpace: "⇧⌘ Space"
        case .optionBacktick: "⌥ `"
        case .disabled: "None"
        }
    }
    var keyCode: UInt32 {
        switch self {
        case .optionBacktick: UInt32(kVK_ANSI_Grave)
        default: UInt32(kVK_Space)
        }
    }
    var modifiers: UInt32 {
        switch self {
        case .optionSpace, .optionBacktick: UInt32(optionKey)
        case .controlOptionSpace: UInt32(controlKey | optionKey)
        case .commandShiftSpace: UInt32(cmdKey | shiftKey)
        case .disabled: 0
        }
    }
}

/// Settings people actually change. Everything else is a considered default.
@MainActor
final class Prefs: ObservableObject {
    static let shared = Prefs()
    private static let d = UserDefaults.standard

    private static func bool(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
    private static func int(_ k: String, _ def: Int) -> Int { d.object(forKey: k) as? Int ?? def }
    private static func double(_ k: String, _ def: Double) -> Double { d.object(forKey: k) as? Double ?? def }
    private static func string(_ k: String, _ def: String) -> String { d.string(forKey: k) ?? def }

    // General
    @Published var expandOnHover = Prefs.bool("expandOnHover", true) { didSet { Self.d.set(expandOnHover, forKey: "expandOnHover") } }
    @Published var hoverDelay = Prefs.double("hoverDelay", 0.1) { didSet { Self.d.set(hoverDelay, forKey: "hoverDelay") } }
    @Published var haptics = Prefs.bool("hapticsOn", true) { didSet { Self.d.set(haptics, forKey: "hapticsOn") } }
    @Published var gestures = Prefs.bool("gestures", true) { didSet { Self.d.set(gestures, forKey: "gestures") } }
    @Published var displayMode = DisplayMode(rawValue: Prefs.int("displayMode", 0)) ?? .notchScreen { didSet { Self.d.set(displayMode.rawValue, forKey: "displayMode") } }
    @Published var hotKey = HotKeyChoice(rawValue: Prefs.int("hotKey", 0)) ?? .optionSpace { didSet { Self.d.set(hotKey.rawValue, forKey: "hotKey") } }
    @Published var showMenuBarIcon = Prefs.bool("showMenuBarIcon", true) { didSet { Self.d.set(showMenuBarIcon, forKey: "showMenuBarIcon") } }
    /// Ask GitHub for a new release at launch and once a day.
    @Published var autoUpdate = Prefs.bool("autoUpdate", true) { didSet { Self.d.set(autoUpdate, forKey: "autoUpdate") } }

    // Live Activities
    @Published var nowPlaying = Prefs.bool("la.nowPlaying", true) { didSet { Self.d.set(nowPlaying, forKey: "la.nowPlaying") } }
    @Published var meetings = Prefs.bool("la.meetings", true) { didSet { Self.d.set(meetings, forKey: "la.meetings") } }
    @Published var calls = Prefs.bool("la.calls", true) { didSet { Self.d.set(calls, forKey: "la.calls") } }
    @Published var claude = Prefs.bool("la.claude", true) { didSet { Self.d.set(claude, forKey: "la.claude") } }
    @Published var claudeAlerts = Prefs.bool("al.claude", true) { didSet { Self.d.set(claudeAlerts, forKey: "al.claude") } }
    @Published var downloads = Prefs.bool("la.downloads", false) { didSet { Self.d.set(downloads, forKey: "la.downloads") } }
    @Published var shelfInNotch = Prefs.bool("la.shelf", true) { didSet { Self.d.set(shelfInNotch, forKey: "la.shelf") } }
    @Published var devices = Prefs.bool("la.devices", false) { didSet { Self.d.set(devices, forKey: "la.devices") } }
    @Published var volumeAlerts = Prefs.bool("al.volume", true) { didSet { Self.d.set(volumeAlerts, forKey: "al.volume") } }
    @Published var powerAlerts = Prefs.bool("al.power", true) { didSet { Self.d.set(powerAlerts, forKey: "al.power") } }
    @Published var privacyIndicators = Prefs.bool("al.privacy", true) { didSet { Self.d.set(privacyIndicators, forKey: "al.privacy") } }
    @Published var trackAlerts = Prefs.bool("al.track", true) { didSet { Self.d.set(trackAlerts, forKey: "al.track") } }
    @Published var sounds = Prefs.bool("sounds", true) { didSet { Self.d.set(sounds, forKey: "sounds") } }

    // Search
    @Published var fileSearch = Prefs.bool("fileSearch", true) { didSet { Self.d.set(fileSearch, forKey: "fileSearch") } }
    @Published var onlineCurrency = Prefs.bool("onlineCurrency", true) { didSet { Self.d.set(onlineCurrency, forKey: "onlineCurrency") } }
    @Published var clipboardEnabled = Prefs.bool("clipboardEnabled", true) { didSet { Self.d.set(clipboardEnabled, forKey: "clipboardEnabled") } }
    @Published var clipboardImages = Prefs.bool("clipboardImages", true) { didSet { Self.d.set(clipboardImages, forKey: "clipboardImages") } }
    @Published var pasteOnReturn = Prefs.bool("pasteOnReturn", false) { didSet { Self.d.set(pasteOnReturn, forKey: "pasteOnReturn") } }

    // Glance
    @Published var weatherEnabled = Prefs.bool("weatherEnabled", false) { didSet { Self.d.set(weatherEnabled, forKey: "weatherEnabled") } }
    @Published var weatherCity = Prefs.string("weatherCity", "") { didSet { Self.d.set(weatherCity, forKey: "weatherCity") } }
    @Published var temperatureUnit = TemperatureUnit(rawValue: Prefs.int("temperatureUnit", 0)) ?? .automatic { didSet { Self.d.set(temperatureUnit.rawValue, forKey: "temperatureUnit") } }

    // Desktop widgets
    @Published var widgetsEnabled = Prefs.bool("widgetsEnabled", false) { didSet { Self.d.set(widgetsEnabled, forKey: "widgetsEnabled") } }
    @Published var widgetsDimInApps = Prefs.bool("widgetsDimInApps", true) { didSet { Self.d.set(widgetsDimInApps, forKey: "widgetsDimInApps") } }
    @Published var worldClocks = (UserDefaults.standard.stringArray(forKey: "worldClocks")
        ?? ["Europe/London", "America/New_York", "Asia/Tokyo", "Australia/Sydney"]) { didSet { Self.d.set(worldClocks, forKey: "worldClocks") } }

    // StandBy
    @Published var standByEnabled = Prefs.bool("standByEnabled", false) { didSet { Self.d.set(standByEnabled, forKey: "standByEnabled") } }
    @Published var standByDelay = Prefs.double("standByDelay", 300) { didSet { Self.d.set(standByDelay, forKey: "standByDelay") } }
    @Published var standByChargingOnly = Prefs.bool("standByChargingOnly", true) { didSet { Self.d.set(standByChargingOnly, forKey: "standByChargingOnly") } }
    /// Dim red clock 10 PM–6 AM (the iPhone's bedside idea): off unless you ask for it, and never on Now Playing.
    @Published var standByNightMode = Prefs.bool("standByNightRed", false) { didSet { Self.d.set(standByNightMode, forKey: "standByNightRed") } }
    @Published var standByClockStyle = Prefs.int("standByClockStyle", StandByClockStyle.glass.rawValue) { didSet { Self.d.set(standByClockStyle, forKey: "standByClockStyle") } }
    @Published var standByAccent = Prefs.int("standByAccent", 0) { didSet { Self.d.set(standByAccent, forKey: "standByAccent") } }
    /// A wallpaper's id, "shuffle" (a different one each time) or "none" (black).
    @Published var standByWallpaper = Prefs.string("standByWallpaper", Wallpapers.shuffle) { didSet { Self.d.set(standByWallpaper, forKey: "standByWallpaper") } }
    /// Tuck the time behind the wallpaper's foreground, on the pictures that have one.
    @Published var standByDepth = Prefs.bool("standByDepth", true) { didSet { Self.d.set(standByDepth, forKey: "standByDepth") } }
    /// Open on Now Playing while music plays, and turn to it when a song starts.
    @Published var standByMusicFirst = Prefs.bool("standByMusicFirst", true) { didSet { Self.d.set(standByMusicFirst, forKey: "standByMusicFirst") } }
    /// Time-synced lyrics beside the song (asks LRCLIB by title, artist, album and length).
    @Published var standByLyrics = Prefs.bool("standByLyrics", true) { didSet { Self.d.set(standByLyrics, forKey: "standByLyrics"); LyricsModel.shared.reload() } }

    // Dock
    @Published var dockCompanion = Prefs.bool("dockCompanion", false) { didSet { Self.d.set(dockCompanion, forKey: "dockCompanion") } }
    @Published var dockDropZone = Prefs.bool("dockDropZone", false) { didSet { Self.d.set(dockDropZone, forKey: "dockDropZone") } }
    @Published var showInDock = Prefs.bool("showInDock", false) { didSet { Self.d.set(showInDock, forKey: "showInDock") } }

    // Brain
    @Published var brainLevel = Prefs.int("brainLevel", BrainLevel.essentials.rawValue) { didSet { Self.d.set(brainLevel, forKey: "brainLevel") } }
    @Published var brainSuggestions = Prefs.bool("brainSuggestions", true) { didSet { Self.d.set(brainSuggestions, forKey: "brainSuggestions") } }
    /// The first time you open the Mac each morning, the island asks you to plan the day.
    @Published var planMorning = Prefs.bool("planMorning", true) { didSet { Self.d.set(planMorning, forKey: "planMorning") } }
    /// Your workday, for placing priorities.
    @Published var planStartHour = Prefs.int("planStartHour", 9) { didSet { Self.d.set(planStartHour, forKey: "planStartHour") } }
    @Published var planEndHour = Prefs.int("planEndHour", 19) { didSet { Self.d.set(planEndHour, forKey: "planEndHour") } }
    /// While a focus block runs, dim everything but the window you're working in.
    @Published var dimFocus = Prefs.bool("dimFocus", true) { didSet { Self.d.set(dimFocus, forKey: "dimFocus") } }
    /// Setting a room hides the apps that aren't part of it.
    @Published var roomHidesOthers = Prefs.bool("roomHidesOthers", true) { didSet { Self.d.set(roomHidesOthers, forKey: "roomHidesOthers") } }
    /// Shortcuts run when a room is set and when its block ends (macOS has no API for apps to turn on Focus).
    @Published var focusShortcutOn = Prefs.string("focusShortcutOn", "") { didSet { Self.d.set(focusShortcutOn, forKey: "focusShortcutOn") } }
    @Published var focusShortcutOff = Prefs.string("focusShortcutOff", "") { didSet { Self.d.set(focusShortcutOff, forKey: "focusShortcutOff") } }
    /// At quiet moments, a card to recall from what you saved to learn.
    @Published var learnQuizzes = Prefs.bool("learnQuizzes", true) { didSet { Self.d.set(learnQuizzes, forKey: "learnQuizzes") } }
    /// The Brief: headlines from the feeds in Settings › Flow, ranked by your interests.
    @Published var newsEnabled = Prefs.bool("newsEnabled", true) { didSet { Self.d.set(newsEnabled, forKey: "newsEnabled") } }
    /// Flow Lens: next steps for meaningful copies, and for files dropped on the notch.
    @Published var flowLens = Prefs.bool("flowLens", true) { didSet { Self.d.set(flowLens, forKey: "flowLens") } }
    /// Press and hold the notch to talk to Flow.
    @Published var holdToTalk = Prefs.bool("holdToTalk", true) { didSet { Self.d.set(holdToTalk, forKey: "holdToTalk") } }
    /// Offer to take notes in meetings (transcribed on this Mac; off until you turn it on).
    @Published var meetingNotes = Prefs.bool("meetingNotes", false) { didSet { Self.d.set(meetingNotes, forKey: "meetingNotes") } }
    @Published var brainRetentionDays = Prefs.int("brainRetentionDays", 90) { didSet { Self.d.set(brainRetentionDays, forKey: "brainRetentionDays") } }
    @Published var brainExcluded = (UserDefaults.standard.stringArray(forKey: "brainExcluded") ?? []) { didSet { Self.d.set(brainExcluded, forKey: "brainExcluded") } }
    @Published var brainPausedUntil = UserDefaults.standard.object(forKey: "brainPausedUntil") as? Date { didSet { Self.d.set(brainPausedUntil, forKey: "brainPausedUntil") } }

    @Published var hasOnboarded = Prefs.bool("hasOnboarded5", false) { didSet { Self.d.set(hasOnboarded, forKey: "hasOnboarded5") } }
}
