import Foundation
import Combine
import CryptoKit
import SwiftUI

/// One line of a song. `time` is when it starts, in seconds into the song. An empty `text` is a gap — an intro,
/// a solo, a break — long enough to show the breathing dots instead of words.
struct LyricLine: Equatable, Codable {
    var time: Double
    var text: String
    var isGap: Bool { text.isEmpty }
}

struct Lyrics: Equatable, Codable {
    var lines: [LyricLine]
    /// Lines carry their start times. Without them the lyrics scroll with the song's progress instead.
    var synced: Bool
    /// Where they came from ("lrclib", "music"), for `atoll://diagnose`.
    var source: String

    /// The line being sung at `t` (nil before the first one starts).
    func index(at t: Double) -> Int? {
        guard synced, let first = lines.first, t >= first.time else { return nil }
        var lo = 0, hi = lines.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lines[mid].time <= t { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// When line `i` gives way to the next (the song's end for the last).
    func end(of i: Int, duration: Double) -> Double {
        i + 1 < lines.count ? lines[i + 1].time : max(duration, lines[i].time + 5)
    }

    /// Lyrics without timing: lines spread across the song, skipping a short intro and outro.
    static func plain(_ text: String, source: String) -> Lyrics? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return Lyrics(lines: lines.map { LyricLine(time: 0, text: $0) }, synced: false, source: source)
    }

    /// Time-synced lyrics from LRC text, with gaps where the song has room to breathe.
    static func synced(lrc: String, source: String) -> Lyrics? {
        let lines = LRC.timed(LRC.parse(lrc))
        guard lines.contains(where: { !$0.isGap }) else { return nil }
        return Lyrics(lines: lines, synced: true, source: source)
    }
}

// MARK: - LRC

/// The LRC format: `[mm:ss.xx] words`, several stamps per line allowed, `[offset:±ms]`, metadata tags ignored,
/// and "enhanced" `<mm:ss.xx>` word stamps stripped (line timing is what Mac Flow shows).
enum LRC {
    /// The shortest silence worth showing as a gap.
    static let minGap: Double = 5
    /// A sung line rarely lasts longer than this; a longer stretch to the next line is a break.
    static let longestLine: Double = 7

    static func parse(_ text: String) -> [LyricLine] {
        var offset = 0.0
        var out: [(order: Int, line: LyricLine)] = []
        for raw in text.components(separatedBy: .newlines) {
            var rest = Substring(raw.trimmingCharacters(in: .whitespaces))
            var stamps: [Double] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                if let t = time(tag) {
                    stamps.append(t)
                } else if tag.lowercased().hasPrefix("offset:") {
                    offset = (Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) ?? 0) / 1000
                }
                rest = rest[rest.index(after: close)...]
            }
            guard !stamps.isEmpty else { continue }
            let words = String(rest)
                .replacingOccurrences(of: #"<\d+:\d+(?:[.:]\d+)?>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            for t in stamps { out.append((out.count, LyricLine(time: t, text: words))) }
        }
        // A positive offset makes lyrics appear sooner.
        return out.sorted { $0.line.time == $1.line.time ? $0.order < $1.order : $0.line.time < $1.line.time }
            .map { LyricLine(time: max(0, $0.line.time - offset), text: $0.line.text) }
    }

    /// `mm:ss`, `mm:ss.xx` or `mm:ss:xx`.
    static func time(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3, let m = Double(parts[0]), let s = Double(parts[1]), m >= 0, s >= 0 else { return nil }
        var t = m * 60 + s
        if parts.count == 3 {
            guard let f = Double(parts[2]) else { return nil }
            t += f / pow(10, Double(parts[2].count))
        }
        return t
    }

    /// Phrase ends that are only a breath are dropped; real breaks (and a long intro) become one gap each.
    static func timed(_ parsed: [LyricLine]) -> [LyricLine] {
        let lines = parsed.map { l -> LyricLine in
            let t = l.text.trimmingCharacters(in: .whitespaces)
            // A line that's only a music note is a break, not words.
            return LyricLine(time: l.time, text: t.allSatisfy { "♪♫♬♩~-– ".contains($0) } ? "" : t)
        }
        var out: [LyricLine] = []
        for (i, line) in lines.enumerated() {
            let next = lines[(i + 1)...].first(where: { !$0.isGap })?.time
            if line.isGap {
                guard let next, next - line.time >= minGap, out.last?.isGap != true else { continue }
                out.append(line)
            } else {
                if out.isEmpty, line.time >= minGap { out.append(LyricLine(time: 0, text: "")) }
                out.append(line)
                // A long silence after a line with no blank to mark it: let the line stand, then breathe.
                if let next, i + 1 < lines.count, !lines[i + 1].isGap, next - line.time >= longestLine + minGap {
                    out.append(LyricLine(time: line.time + longestLine, text: ""))
                }
            }
        }
        return out
    }
}

// MARK: - LRCLIB

/// LRCLIB (lrclib.net): an open lyrics database, free and without an account. Asked with the song's title, artist,
/// album and length — the same fields the cover lookup sends to Apple's catalog — and nothing about you.
enum LRCLib {
    struct Record: Decodable, Equatable {
        var trackName: String?
        var artistName: String?
        var albumName: String?
        var duration: Double?
        var instrumental: Bool?
        var plainLyrics: String?
        var syncedLyrics: String?
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 10
        c.httpAdditionalHeaders = ["User-Agent": "MacFlow/8.0 (macOS)"]
        return URLSession(configuration: c)
    }()

    private static func url(_ path: String, _ items: [String: String]) -> URL? {
        var c = URLComponents(string: "https://lrclib.net/api/\(path)")
        c?.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c?.url
    }

    /// The exact song, matched by LRCLIB on all four fields (it allows ±2 s on the length).
    static func get(title: String, artist: String, album: String, duration: Double) async -> Record? {
        guard duration > 0, let u = url("get", ["track_name": title, "artist_name": artist, "album_name": album,
                                               "duration": String(Int(duration.rounded()))]),
              let (data, response) = try? await session.data(from: u),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    static func search(title: String, artist: String) async -> [Record] {
        guard let u = url("search", ["track_name": ArtworkStore.clean(title), "artist_name": artist]),
              let (data, response) = try? await session.data(from: u),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return (try? JSONDecoder().decode([Record].self, from: data)) ?? []
    }

    /// The closest record by length (±3 s) whose title and artist agree, synced lyrics first. Nothing below a
    /// confident match — wrong lyrics are worse than none.
    static func best(_ records: [Record], title: String, artist: String, duration: Double) -> Record? {
        let ct = ArtworkStore.clean(title), ca = ArtworkStore.norm(artist)
        let fits = records.filter { r in
            let rt = ArtworkStore.clean(r.trackName ?? ""), ra = ArtworkStore.norm(r.artistName ?? "")
            let titled = rt == ct || (!ct.isEmpty && (rt.hasPrefix(ct) || ct.hasPrefix(rt)))
            let byArtist = !ca.isEmpty && !ra.isEmpty && (ra.contains(ca) || ca.contains(ra)
                || ca.components(separatedBy: CharacterSet(charactersIn: ",&")).contains { p in
                    let p = p.trimmingCharacters(in: .whitespaces); return !p.isEmpty && ra.contains(p) })
            let timed = duration <= 0 || abs((r.duration ?? 0) - duration) <= 3
            return titled && byArtist && timed && (r.instrumental == true || r.syncedLyrics?.isEmpty == false || r.plainLyrics?.isEmpty == false)
        }
        return fits.min { a, b in
            let sa = a.syncedLyrics?.isEmpty == false, sb = b.syncedLyrics?.isEmpty == false
            if sa != sb { return sa }
            return abs((a.duration ?? 0) - duration) < abs((b.duration ?? 0) - duration)
        }
    }
}

// MARK: - Model

/// Lyrics for the song that's playing, fetched only while something on screen shows them (StandBy's Now Playing),
/// and remembered on this Mac so each song is asked for once.
@MainActor
final class LyricsModel: ObservableObject {
    static let shared = LyricsModel()

    enum Status: Equatable { case idle, loading, ready, instrumental, none }

    @Published private(set) var lyrics: Lyrics?
    @Published private(set) var status: Status = .idle
    private var key = ""
    private var following: AnyCancellable?

    /// Start or stop following the player.
    func follow(_ on: Bool) {
        guard on else { following = nil; return }
        guard following == nil else { return }
        let np = NowPlayingModel.shared
        following = Publishers.CombineLatest4(np.$title, np.$artist, np.$album, np.$duration)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] title, artist, album, duration in
                MainActor.assumeIsolated { self?.load(title: title, artist: artist, album: album, duration: duration) }
            }
    }

    /// Look again for the song that's playing (after Show Lyrics is turned on).
    func reload() {
        key = ""
        guard following != nil else { return }
        let np = NowPlayingModel.shared
        load(title: np.title, artist: np.artist, album: np.album, duration: np.duration)
    }

    private static func cacheKey(title: String, artist: String, album: String) -> String {
        "\(ArtworkStore.clean(title))|\(ArtworkStore.norm(artist))|\(ArtworkStore.clean(album))"
    }

    func load(title: String, artist: String, album: String, duration: Double) {
        guard Prefs.shared.standByLyrics, !title.isEmpty else {
            key = ""
            set(nil, .idle)
            return
        }
        let k = Self.cacheKey(title: title, artist: artist, album: album)
        // Music reports a song before its length; wait for the length rather than ask twice.
        guard k != key, duration > 0 || NowPlayingModel.shared.source == .spotify else { return }
        key = k
        if let hit = LyricsCache.read(k) {
            set(hit.lyrics, hit.lyrics != nil ? .ready : hit.instrumental ? .instrumental : .none)
            return
        }
        set(nil, .loading)
        let source = NowPlayingModel.shared.source
        Task { @MainActor [weak self] in
            var found: Lyrics?
            var instrumental = false
            if !RenderMode.snapshot {
                var record = await LRCLib.get(title: title, artist: artist, album: album, duration: duration)
                if record == nil || (record?.syncedLyrics?.isEmpty != false && record?.instrumental != true) {
                    let alt = LRCLib.best(await LRCLib.search(title: title, artist: artist), title: title, artist: artist, duration: duration)
                    if alt?.syncedLyrics?.isEmpty == false || record == nil { record = alt ?? record }
                }
                if let r = record {
                    instrumental = r.instrumental == true
                    found = r.syncedLyrics.flatMap { Lyrics.synced(lrc: $0, source: "lrclib") }
                        ?? r.plainLyrics.flatMap { Lyrics.plain($0, source: "lrclib") }
                }
                if found == nil, !instrumental, source == .music, let text = await NowPlayingModel.shared.musicLyrics() {
                    found = Lyrics.plain(text, source: "music")
                }
            }
            guard let self, self.key == k else { return }
            LyricsCache.write(k, .init(lyrics: found, instrumental: instrumental, at: Date()))
            self.set(found, found != nil ? .ready : instrumental ? .instrumental : .none)
        }
    }

    private func set(_ lyrics: Lyrics?, _ status: Status) {
        guard lyrics != self.lyrics || status != self.status else { return }
        withAnimation(Motion.duo) {
            self.lyrics = lyrics
            self.status = status
        }
    }

    #if DEBUG
    func debugSet(_ lyrics: Lyrics?) {
        key = "debug"
        self.lyrics = lyrics
        status = lyrics == nil ? .none : .ready
    }
    #endif
}

/// One small JSON file per song in ~/Library/Application Support/Atoll/Lyrics. "None found" is kept too, for a week,
/// so a song without lyrics isn't asked for every time it plays.
enum LyricsCache {
    struct Entry: Codable {
        var lyrics: Lyrics?
        var instrumental: Bool
        var at: Date
    }

    private static let folder: URL = {
        let dir = Storage.directory.appendingPathComponent("Lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func file(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash + ".json")
    }

    static func read(_ key: String) -> Entry? {
        guard let data = try? Data(contentsOf: file(key)), let e = try? JSONDecoder().decode(Entry.self, from: data) else { return nil }
        if e.lyrics == nil, !e.instrumental, Date().timeIntervalSince(e.at) > 7 * 86_400 { return nil }
        return e
    }

    static func write(_ key: String, _ entry: Entry) {
        guard !Storage.readOnly, let data = try? JSONEncoder().encode(entry) else { return }
        let url = file(key)
        DispatchQueue.global(qos: .utility).async { try? data.write(to: url, options: .atomic) }
    }
}
