import AppKit
import SwiftUI
import CoreImage
import os

enum MediaSource: String, CaseIterable {
    case spotify = "com.spotify.client"
    case music = "com.apple.Music"

    var name: String { self == .spotify ? "Spotify" : "Music" }
    var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty }
    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) }
    /// Asked by Home on every render; a LaunchServices lookup each time, so remembered for a few minutes.
    var isInstalled: Bool {
        let now = Date()
        if let hit = Self.installed.withLock({ $0[self] }), now.timeIntervalSince(hit.at) < 300 { return hit.value }
        let value = appURL != nil
        Self.installed.withLock { $0[self] = (value, now) }
        return value
    }
    private static let installed = OSAllocatedUnfairLock<[MediaSource: (value: Bool, at: Date)]>(initialState: [:])
    @MainActor var icon: NSImage? { IconCache.app(bundleID: rawValue) }
}

/// Rich tracking for Apple Music and Spotify (distributed notifications + Apple Events),
/// plus universal detection of any other app playing audio (CoreAudio) controlled via media keys.
@MainActor
final class NowPlayingModel: NSObject, ObservableObject {
    static let shared = NowPlayingModel()

    @Published private(set) var title = ""
    @Published private(set) var artist = ""
    @Published private(set) var album = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var source: MediaSource?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent = Color(red: 0.62, green: 0.58, blue: 1.0)
    /// The cover boiled down to a few pixels of its own colours. Stretched with smooth interpolation it becomes
    /// the immersive colour field behind the player — Apple Music's look, with no live blur.
    @Published private(set) var palette: NSImage?
    /// The cover's two most distinct vivid colours (left and right of the closed island).
    @Published private(set) var duo: (Color, Color)?
    private var artCache: [String: NSImage] = [:]
    /// Where the current cover came from and how long it took (for `atoll://diagnose`).
    private var artSource = ""
    /// The song the cover on show belongs to (the previous song's stays up while the next one's loads).
    private var coverKey = ""
    private var artRequested = Date()
    private(set) var lastArt: (source: String, ms: Int) = ("", 0)
    /// How many times the track has changed (tests: one song must count once).
    private(set) var changeCount = 0

    /// Tests: what a player reported, exactly as the notification or AppleScript path hands it over.
    func report(source: MediaSource, title: String, artist: String, album: String, key: String?, playing: Bool) {
        apply(source: source, title: title, artist: artist, album: album, duration: 200, position: nil,
              playing: playing, key: key, artworkURL: nil)
    }
    /// The last error a player returned to Atoll's AppleScript, for diagnostics.
    var lastScriptError: String?
    @Published private(set) var trackChangeTick = 0
    /// Another app producing audio (Safari/YouTube, Chrome, Podcasts, VLC…).
    @Published private(set) var otherApp: AudioApp?
    @Published private(set) var needsAccessibility = false

    enum Mode: Equatable { case idle, track, app }

    /// What the UI should feature right now.
    var mode: Mode {
        if hasTrack && isPlaying { return .track }
        if otherApp != nil { return .app }
        return hasTrack ? .track : .idle
    }

    /// Whether something audible is live (drives the collapsed live activity).
    var isLive: Bool { (hasTrack && isPlaying) || otherApp != nil }
    private var audioCancellable: Any?

    private var elapsed: Double = 0
    private var elapsedDate = Date()
    private var trackKey = ""
    private var didInitialLoad = false
    private let scriptQueue = appleScriptQueue

    var hasTrack: Bool { !title.isEmpty }

    override init() {
        super.init()
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(self, selector: #selector(musicChanged(_:)),
                        name: NSNotification.Name("com.apple.Music.playerInfo"),
                        object: nil, suspensionBehavior: .deliverImmediately)
        dnc.addObserver(self, selector: #selector(spotifyChanged(_:)),
                        name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
                        object: nil, suspensionBehavior: .deliverImmediately)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appTerminated(_:)),
                                                          name: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil)
        audioCancellable = AudioActivity.shared.$playing
            .receive(on: RunLoop.main)
            .sink { [weak self] apps in
                let richIDs = Set(MediaSource.allCases.map(\.rawValue))
                let other = apps.first { !richIDs.contains($0.id) }
                if self?.otherApp != other {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) { self?.otherApp = other }
                }
            }
        // At launch, sync only with players Atoll is already allowed to ask (never prompting before the user has
        // even seen the app). Notifications cover live changes; opening the island re-syncs.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.didInitialLoad = true
            for s in MediaSource.allCases where s.isRunning && Self.automationAllowed(s) == .allowed { self?.fetchStatus(s) }
        }
    }

    enum Permission: String { case allowed, denied, notAsked, notRunning }

    /// Whether macOS lets Atoll send Apple Events to a player — without ever showing the prompt.
    nonisolated static func automationAllowed(_ s: MediaSource) -> Permission {
        var target = AEAddressDesc()
        let bundle = s.rawValue
        let status: OSStatus = bundle.withCString { ptr in
            AECreateDesc(typeApplicationBundleID, ptr, strlen(ptr), &target)
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, typeWildCard, typeWildCard, false)
        }
        switch status {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        case OSStatus(procNotFound): return .notRunning
        default: return .denied
        }
    }

    private var syncTimer: Timer?
    /// Who wants the player re-read (the open island, StandBy): the timer runs while anyone does.
    private var syncReasons = Set<String>()

    /// Re-read the player every few seconds while it's on screen: seeking in Music or Spotify sends no notification.
    func keepSynced(_ on: Bool, for reason: String = "island") {
        if on { syncReasons.insert(reason) } else { syncReasons.remove(reason) }
        let on = !syncReasons.isEmpty
        if on, syncTimer == nil {
            let t = Timer(timeInterval: 4, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let me = NowPlayingModel.shared
                    if let s = me.source, me.isPlaying { me.fetchStatus(s) }
                }
            }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            syncTimer = t
        } else if !on {
            syncTimer?.invalidate()
            syncTimer = nil
        }
    }

    func position(at date: Date = Date()) -> Double {
        let p = isPlaying ? elapsed + date.timeIntervalSince(elapsedDate) : elapsed
        return duration > 0 ? min(max(0, p), duration) : max(0, p)
    }

    // MARK: - Notifications

    @objc private func spotifyChanged(_ note: Notification) {
        guard let info = note.userInfo else { return }
        let state = (info["Player State"] as? String) ?? ""
        if state == "Stopped" {
            if source == .spotify { clear() }
            return
        }
        let playing = state == "Playing"
        if !playing, source == .music, isPlaying { return }
        apply(source: .spotify,
              title: info["Name"] as? String ?? "",
              artist: info["Artist"] as? String ?? "",
              album: info["Album"] as? String ?? "",
              duration: ((info["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000,
              position: (info["Playback Position"] as? NSNumber)?.doubleValue,
              playing: playing,
              key: info["Track ID"] as? String,
              artworkURL: nil)
    }

    @objc private func musicChanged(_ note: Notification) {
        guard let info = note.userInfo else { return }
        let state = (info["Player State"] as? String) ?? ""
        if state == "Stopped" {
            if source == .music { clear() }
            return
        }
        let playing = state == "Playing"
        if !playing, source == .spotify, isPlaying { return }
        let name = info["Name"] as? String ?? ""
        let artist = info["Artist"] as? String ?? ""
        let pid = (info["PersistentID"] as? NSNumber)?.stringValue
        apply(source: .music,
              title: name,
              artist: artist,
              album: info["Album"] as? String ?? "",
              duration: ((info["Total Time"] as? NSNumber)?.doubleValue ?? 0) / 1000,
              position: nil,
              playing: playing,
              key: pid ?? "\(name)|\(artist)",
              artworkURL: nil)
        fetchStatus(.music)
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier == source?.rawValue else { return }
        clear()
    }

    // MARK: - State

    private func apply(source: MediaSource, title: String, artist: String, album: String,
                       duration: Double, position: Double?, playing: Bool, key: String?, artworkURL: String?) {
        let current = self.position()
        // A song is the same song whichever way we heard about it. Music's notification carries no ID for streamed
        // songs (and a decimal one for library songs) while AppleScript reports a hex persistent ID — keying on those
        // made every song "change" twice, throwing its first cover away. Title, artist and album come from both.
        let newKey = "\(source.rawValue)|\(title)|\(artist)|\(album)"
        let changed = newKey != trackKey || source != self.source

        if self.source != source { self.source = source }
        if self.title != title { self.title = title }
        if self.artist != artist { self.artist = artist }
        if self.album != album { self.album = album }
        if duration > 0, self.duration != duration { self.duration = duration }

        if let position {
            elapsed = position
        } else if changed {
            elapsed = 0
        } else {
            elapsed = current
        }
        elapsedDate = Date()
        if isPlaying != playing { isPlaying = playing }

        if changed {
            changeCount += 1
            trackKey = newKey
            artRequested = Date()
            let albumKey = ArtworkStore.key(title: title, artist: artist, album: album)
            if let cached = artCache[newKey] ?? ArtworkStore.cached(albumKey) {
                artSource = "memory"
                setArtwork(cached, for: newKey)
            } else {
                // Keep the last cover up while the new one loads (a placeholder flash between songs reads as a glitch);
                // drop it only if nothing arrives.
                let waiting = newKey
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                    guard let self, self.trackKey == waiting, self.coverKey != waiting else { return }
                    withAnimation(.easeInOut(duration: 0.3)) { self.artwork = nil; self.palette = nil }
                }
                // This Mac's cover cache first (instant for anything heard before), then the player, then the catalog.
                let key = newKey
                Self.colorQueue.async {
                    let disk = ArtworkStore.fromDisk(albumKey)
                    nonisolated(unsafe) let found = disk
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.trackKey == key else { return }
                        if let found {
                            self.artSource = "disk"
                            self.setArtwork(found, for: key)
                        } else {
                            self.fetchArtwork(source, url: artworkURL)
                        }
                    }
                }
            }
            if didInitialLoad, playing, !title.isEmpty { trackChangeTick += 1 }
        } else if artwork == nil, let artworkURL {
            fetchArtwork(source, url: artworkURL)
        }
    }

    private func clear() {
        title = ""; artist = ""; album = ""
        isPlaying = false; duration = 0; elapsed = 0
        source = nil; artwork = nil; palette = nil; duo = nil; trackKey = ""
    }

    /// Re-sync from whichever player is running (used on launch and when the island opens).
    func refresh() {
        guard !RenderMode.snapshot else { return }
        lastRefresh = Date()
        for s in MediaSource.allCases where s.isRunning { fetchStatus(s) }
    }

    private var lastRefresh = Date.distantPast

    /// When the island opens: re-sync only if it's been a while, and only after the opening
    /// animation has settled — never inside its first frames.
    func refreshAfterOpening() {
        guard Date().timeIntervalSince(lastRefresh) > 4 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.refresh() }
    }

    private func fetchStatus(_ s: MediaSource) {
        guard s.isRunning else { return }
        let script: String
        switch s {
        case .spotify:
            script = """
            tell application id "com.spotify.client"
                set s to player state as string
                if s is "stopped" then return {s}
                set t to current track
                return {s, name of t, artist of t, album of t, (duration of t) / 1000, player position, artwork url of t, id of t}
            end tell
            """
        case .music:
            script = """
            tell application id "com.apple.Music"
                set s to player state as string
                if s is "stopped" then return {s}
                set t to current track
                return {s, name of t, artist of t, album of t, duration of t, player position, "", (persistent ID of t)}
            end tell
            """
        }
        runAsync(script) { [weak self] d in
            guard let self, let d, d.numberOfItems >= 1 else { return }
            let state = d.atIndex(1)?.stringValue ?? ""
            if state == "stopped" {
                if self.source == s { self.clear() }
                return
            }
            guard d.numberOfItems >= 8 else { return }
            let playing = state == "playing"
            if !playing, let cur = self.source, cur != s, self.isPlaying { return }
            self.apply(source: s,
                       title: d.atIndex(2)?.stringValue ?? "",
                       artist: d.atIndex(3)?.stringValue ?? "",
                       album: d.atIndex(4)?.stringValue ?? "",
                       duration: d.atIndex(5)?.doubleValue ?? 0,
                       position: d.atIndex(6)?.doubleValue,
                       playing: playing,
                       key: d.atIndex(8)?.stringValue,
                       artworkURL: d.atIndex(7)?.stringValue)
        }
    }

    // MARK: - Artwork

    private func fetchArtwork(_ s: MediaSource, url: String?) {
        let key = trackKey
        switch s {
        case .spotify:
            if let url, let u = URL(string: url) {
                URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
                    guard let data, let img = NSImage(data: data) else { return }
                    DispatchQueue.main.async {
                        self?.artSource = "spotify"
                        self?.setArtwork(img, for: key)
                    }
                }.resume()
            } else {
                runAsync("tell application id \"com.spotify.client\" to return artwork url of current track") { [weak self] d in
                    guard let self, let str = d?.stringValue, !str.isEmpty, key == self.trackKey else { return }
                    self.fetchArtwork(.spotify, url: str)
                }
            }
        case .music:
            musicArtwork(key: key, attempt: 0)
        }
    }

    /// Music's own cover first. A streamed song's cover often reaches Music a moment after the song starts, so an
    /// empty answer is asked again at 0.8 s and 2 s — while Apple's catalog is tried in parallel; first answer wins.
    private func musicArtwork(key: String, attempt: Int) {
        let (title, artist, album) = (self.title, self.artist, self.album)
        runAsync("tell application id \"com.apple.Music\" to if (count of artworks of current track) > 0 then return raw data of artwork 1 of current track") { [weak self] d in
                guard let self, key == self.trackKey else { return }
                if let data = d?.data, let img = NSImage(data: data) {
                    if self.coverKey != key || self.artSource == "catalog" { self.artSource = "music" }
                    self.setArtwork(img, for: key)
                } else if attempt < 2 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0.8 : 1.2)) { [weak self] in
                        guard let self, key == self.trackKey, self.coverKey != key else { return }
                        self.musicArtwork(key: key, attempt: attempt + 1)
                    }
                    if attempt == 0 { self.catalogArtwork(key: key, title: title, artist: artist, album: album) }
                }
        }
    }

    private func catalogArtwork(key: String, title: String, artist: String, album: String) {
        let albumKey = ArtworkStore.key(title: title, artist: artist, album: album)
        Task { @MainActor [weak self] in
            guard let img = await ArtworkStore.catalog(title: title, artist: artist, album: album, key: albumKey),
                  let self, key == self.trackKey, self.coverKey != key else { return }
            self.artSource = "catalog"
            self.setArtwork(img, for: key)
        }
    }

    /// Covers arrive as 1000–3000 px JPEGs that decode lazily — on the main thread, the first time the island draws
    /// them, mid-animation. Decode and shrink them here first, off the main thread, to what the island can show.
    private func setArtwork(_ image: NSImage, for key: String) {
        guard key == trackKey else { return }
        nonisolated(unsafe) let raw = image
        Self.colorQueue.async {
            let ready = Self.decoded(raw, maxPixels: 600)
            nonisolated(unsafe) let result = ready ?? raw
            DispatchQueue.main.async { [weak self] in self?.applyArtwork(result, for: key) }
        }
    }

    nonisolated private static func decoded(_ image: NSImage, maxPixels: CGFloat) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = CGFloat(cg.width), h = CGFloat(cg.height)
        let s = min(1, maxPixels / max(w, h, 1))
        let pw = max(1, Int((w * s).rounded())), ph = max(1, Int((h * s).rounded()))
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: pw, height: ph))
        guard let small = ctx.makeImage() else { return nil }
        return NSImage(cgImage: small, size: NSSize(width: CGFloat(pw) / 2, height: CGFloat(ph) / 2))
    }

    private func applyArtwork(_ image: NSImage, for key: String) {
        guard key == trackKey else { return }
        coverKey = key
        artCache[key] = image
        let albumKey = ArtworkStore.key(title: title, artist: artist, album: album)
        if artSource != "memory" && artSource != "disk" { ArtworkStore.store(image, for: albumKey) }
        lastArt = (artSource, Int(Date().timeIntervalSince(artRequested) * 1000))
        if artCache.count > 40 { artCache.removeAll() }
        withAnimation(.easeInOut(duration: 0.35)) { artwork = image }
        // Colour work is image work: off the main thread so it never costs a frame.
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        nonisolated(unsafe) let source = cg
        Self.colorQueue.async {
            let color = Self.vibrantAverage(of: source)
            let field = Self.colourField(of: source)
            let duo = Self.duo(of: source)
            DispatchQueue.main.async { [weak self] in
                guard let self, key == self.trackKey else { return }
                withAnimation(.easeInOut(duration: 0.6)) {
                    if let color { self.accent = color }
                    self.palette = field
                    self.duo = duo
                }
            }
        }
    }

    /// The two most distinct vivid colours of the cover: the most vivid, then the one furthest from it in hue.
    nonisolated private static func duo(of cg: CGImage) -> (Color, Color)? {
        let w = 8, h = 8
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let _ = Optional(ctx.interpolationQuality = .high) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let px = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var cells: [(h: CGFloat, s: CGFloat, b: CGFloat)] = []
        for i in 0..<(w * h) {
            let c = NSColor(srgbRed: CGFloat(px[i * 4]) / 255, green: CGFloat(px[i * 4 + 1]) / 255, blue: CGFloat(px[i * 4 + 2]) / 255, alpha: 1)
            var hh: CGFloat = 0, ss: CGFloat = 0, bb: CGFloat = 0, aa: CGFloat = 0
            c.getHue(&hh, saturation: &ss, brightness: &bb, alpha: &aa)
            cells.append((hh, ss, bb))
        }
        func vivid(_ c: (h: CGFloat, s: CGFloat, b: CGFloat)) -> CGFloat { c.s * (0.35 + c.b) }
        guard let first = cells.max(by: { vivid($0) < vivid($1) }) else { return nil }
        func hueGap(_ a: CGFloat, _ b: CGFloat) -> CGFloat { let d = abs(a - b); return min(d, 1 - d) }
        let second = cells.filter { $0.s > 0.18 && $0.b > 0.18 }.max { hueGap($0.h, first.h) * vivid($0) < hueGap($1.h, first.h) * vivid($1) } ?? first
        // Lifted so they glow on black.
        func color(_ c: (h: CGFloat, s: CGFloat, b: CGFloat)) -> Color {
            Color(hue: Double(c.h), saturation: Double(min(1, max(c.s * 1.2, c.s < 0.08 ? c.s : 0.5))), brightness: Double(max(c.b, 0.85)))
        }
        return (color(first), color(second))
    }

    /// The cover averaged down to 6×4 pixels, a touch more saturated so it glows on black.
    nonisolated private static func colourField(of cg: CGImage) -> NSImage? {
        let w = 6, h = 4
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let small = ctx.makeImage(), let bytes = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // Dark covers would give a field you can't see: lift exposure until the average reaches a glow, as Apple Music does.
        var lum = 0.0
        for i in 0..<(w * h) {
            let o = i * 4
            lum += (0.2126 * Double(bytes[o]) + 0.7152 * Double(bytes[o + 1]) + 0.0722 * Double(bytes[o + 2])) / 255
        }
        lum = max(0.02, lum / Double(w * h))
        let ev = min(2.6, max(0, log2(0.36 / lum)))
        let ci = CIImage(cgImage: small)
            .applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.55, kCIInputBrightnessKey: 0.0])
        guard let out = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        // Upscale once, bicubic, so it can be stretched by the GPU without visible facets.
        let W = 72, H = 48
        guard let big = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        big.interpolationQuality = .high
        big.draw(out, in: CGRect(x: 0, y: 0, width: W, height: H))
        guard let smooth = big.makeImage() else { return nil }
        return NSImage(cgImage: smooth, size: NSSize(width: W, height: H))
    }

    private static let colorQueue = DispatchQueue(label: "atoll.artwork-colour", qos: .utility)
    nonisolated(unsafe) private static let ciContext = CIContext(options: [.workingColorSpace: NSNull(), .useSoftwareRenderer: false])

    nonisolated private static func vibrantAverage(of cg: CGImage) -> Color? {
        let ci = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: ci, kCIInputExtentKey: CIVector(cgRect: ci.extent)]),
              let out = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(out, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        let ns = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        // Lift dark / muddy covers so the accent always glows on black.
        return Color(hue: h, saturation: min(1, max(s * 1.25, s < 0.08 ? s : 0.45)), brightness: max(b, 0.82))
    }

    #if DEBUG || ATOLL_PROBE
    func debugInjectApp(_ app: AudioApp?) { otherApp = app }
    func debugInject(title: String, artist: String, duration: Double, elapsed: Double, artwork: NSImage?, playing: Bool = true) {
        self.title = title; self.artist = artist; self.duration = duration
        self.elapsed = elapsed; self.elapsedDate = Date(); self.isPlaying = playing
        self.source = title.isEmpty ? nil : .music; self.artwork = artwork
        if let artwork, let cg = artwork.cgImage(forProposedRect: nil, context: nil, hints: nil), let c = Self.vibrantAverage(of: cg) { accent = c }
        palette = artwork.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }.flatMap(Self.colourField)
        duo = artwork.flatMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }.flatMap(Self.duo)
    }
    #endif

    // MARK: - Controls

    func playPause() {
        if mode == .app {
            mediaKey(.playPause)
            return
        }
        let now = position()
        elapsed = now; elapsedDate = Date()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { isPlaying.toggle() }
        command("playpause")
    }

    func next() { mode == .app ? mediaKey(.next) : command("next track") }
    func previous() { mode == .app ? mediaKey(.previous) : command("previous track") }

    var canControl: Bool { mode == .track || (mode == .app && InputControl.isTrusted) }

    private func mediaKey(_ key: InputControl.MediaKey) {
        if !InputControl.send(key) {
            needsAccessibility = true
            InputControl.requestTrust()
        } else {
            needsAccessibility = false
        }
    }

    func seek(to seconds: Double) {
        elapsed = seconds; elapsedDate = Date()
        command(String(format: "set player position to %.2f", locale: Locale(identifier: "en_US_POSIX"), seconds))
    }

    /// The lyrics Music keeps with the current track (library songs with lyrics embedded), or nil.
    func musicLyrics() async -> String? {
        guard source == .music else { return nil }
        return await withCheckedContinuation { done in
            runAsync("tell application id \"com.apple.Music\" to return lyrics of current track") { d in
                let text = d?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                done.resume(returning: text.isEmpty ? nil : text)
            }
        }
    }

    func open(_ s: MediaSource) {
        guard let url = s.appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    func openCurrentApp() {
        if mode == .app, let app = otherApp { app.activate() } else if let s = source { open(s) }
    }

    private func command(_ cmd: String) {
        guard let s = source ?? MediaSource.allCases.first(where: { $0.isRunning }) else { return }
        runAsync("tell application id \"\(s.rawValue)\" to \(cmd)") { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.fetchStatus(s) }
        }
    }

    /// Compiled scripts, kept: compiling one costs tens of milliseconds every time. Only touched on `scriptQueue`.
    nonisolated(unsafe) private static var compiled: [String: NSAppleScript] = [:]

    private func runAsync(_ source: String, completion: ((NSAppleEventDescriptor?) -> Void)? = nil) {
        scriptQueue.async {
            var error: NSDictionary?
            let script: NSAppleScript? = {
                if let s = Self.compiled[source] { return s }
                guard let s = NSAppleScript(source: source) else { return nil }
                var compileError: NSDictionary?
                if s.compileAndReturnError(&compileError), source.count < 600, Self.compiled.count < 40 { Self.compiled[source] = s }
                return s
            }()
            let result = script?.executeAndReturnError(&error)
            let value = error == nil ? result : nil
            let failure = error.map { "\($0[NSAppleScript.errorNumber] ?? "?"): \($0[NSAppleScript.errorMessage] ?? "")" }
            DispatchQueue.main.async {
                if let failure { NowPlayingModel.shared.lastScriptError = failure }
                completion?(value)
            }
        }
    }
}
