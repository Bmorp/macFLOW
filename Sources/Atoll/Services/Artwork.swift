import AppKit
import CryptoKit

/// Where covers come from, fastest first: memory → this Mac's cover cache → the player → Apple's catalog.
/// Covers are kept per album (a whole album shows instantly after its first song) and on disk, so a song you've
/// heard before shows its cover the moment it starts, even after a relaunch. Albums the catalog can't match are
/// remembered too, so Atoll never asks twice — Apple's catalog refuses clients that ask too often.
enum ArtworkStore {
    nonisolated(unsafe) private static let memory: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 120
        return c
    }()
    private static let lock = NSLock()
    nonisolated(unsafe) private static var unmatched: [String: Date] = [:]
    nonisolated(unsafe) private static var backoffUntil = Date.distantPast
    nonisolated(unsafe) private static var strikes = 0

    private static let folder: URL = {
        let dir = Storage.directory.appendingPathComponent("Artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// One key per album (or per song, for a single with no album).
    static func key(title: String, artist: String, album: String) -> String {
        let a = clean(album)
        return a.isEmpty ? "song|\(clean(title))|\(norm(artist))" : "album|\(a)|\(norm(artist))"
    }

    static func cached(_ key: String) -> NSImage? { memory.object(forKey: key as NSString) }

    /// Reads the on-disk copy (call off the main thread).
    static func fromDisk(_ key: String) -> NSImage? {
        guard let img = NSImage(contentsOf: file(key)) else { return nil }
        memory.setObject(img, forKey: key as NSString)
        return img
    }

    /// Keeps a cover in memory now and on disk shortly (JPEG, already shrunk for the island).
    static func store(_ image: NSImage, for key: String) {
        memory.setObject(image, forKey: key as NSString)
        nonisolated(unsafe) let img = image
        DispatchQueue.global(qos: .utility).async {
            guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.88]) else { return }
            try? data.write(to: file(key), options: .atomic)
        }
    }

    private static func file(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(hash + ".jpg")
    }

    // MARK: Apple's catalog

    /// Cover art from Apple's public catalog (iTunes Search) for a song the player can't give a cover for — sends
    /// only its title, artist and album, the same as searching for it in the Music app. Your region's store first.
    static func catalog(title: String, artist: String, album: String, key: String) async -> NSImage? {
        guard !title.isEmpty else { return nil }
        let blocked: Bool = lock.withLock {
            if Date() < backoffUntil { return true }
            if let t = unmatched[key], Date().timeIntervalSince(t) < 6 * 3600 { return true }
            return false
        }
        guard !blocked else { return nil }
        let country = Locale.current.region?.identifier ?? "US"
        var url: String?
        guard let songs = await search(term: "\(clean(title)) \(artist)", entity: "song", country: country) else { return nil }
        if let best = bestSong(songs, title: title, artist: artist, album: album) {
            url = best
        } else if !album.isEmpty, let r = await search(term: "\(artist) \(clean(album))", entity: "album", country: country) {
            url = r.first(where: { clean($0["collectionName"] as? String ?? "") == clean(album) && sameArtist($0["artistName"] as? String ?? "", artist) })?["artworkUrl100"] as? String
        }
        guard let small = url, let big = URL(string: small.replacingOccurrences(of: "100x100bb", with: "600x600bb")) else {
            lock.withLock { unmatched[key] = Date() }
            return nil
        }
        guard let (data, _) = try? await URLSession.shared.data(from: big) else { return nil }
        return NSImage(data: data)
    }

    private static func search(term: String, entity: String, country: String) async -> [[String: Any]]? {
        let q = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "https://itunes.apple.com/search?term=\(q)&entity=\(entity)&limit=10&country=\(country)"),
              let (data, response) = try? await URLSession.shared.data(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, http.statusCode == 403 || http.statusCode == 429 {
            // Asked too often (the limit is per connection, ~20 a minute): leave the catalog alone, longer each time.
            lock.withLock {
                strikes = min(strikes + 1, 3)
                backoffUntil = Date().addingTimeInterval([60, 300, 900][strikes - 1])
            }
            return nil
        }
        lock.withLock { strikes = 0 }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]]
    }

    /// The song whose title matches (ignoring "(feat. …)", " - Single" and the like), the artist agreeing, the album
    /// breaking ties. Nothing below a confident match — a wrong cover is worse than none.
    static func bestSong(_ results: [[String: Any]], title: String, artist: String, album: String) -> String? {
        let ct = clean(title)
        let scored = results.map { r -> (Int, [String: Any]) in
            var s = 0
            let rt = clean(r["trackName"] as? String ?? "")
            if rt == ct { s += 4 } else if !ct.isEmpty, rt.hasPrefix(ct) || ct.hasPrefix(rt) { s += 2 }
            if sameArtist(r["artistName"] as? String ?? "", artist) { s += 3 }
            if !album.isEmpty, clean(r["collectionName"] as? String ?? "") == clean(album) { s += 3 }
            return (s, r)
        }
        guard let best = scored.max(by: { $0.0 < $1.0 }), best.0 >= 6 else { return nil }
        return best.1["artworkUrl100"] as? String
    }

    private static func sameArtist(_ a: String, _ b: String) -> Bool {
        let x = norm(a), y = norm(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x.contains(y) || y.contains(x) { return true }
        // "Vedang, Shreyas & N" vs "Vedang": any named artist in common.
        let parts = y.components(separatedBy: CharacterSet(charactersIn: ",&")).map { $0.trimmingCharacters(in: .whitespaces) }
        return parts.contains { !$0.isEmpty && x.contains($0) }
    }

    static func norm(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).trimmingCharacters(in: .whitespaces)
    }

    /// Title or album without the decorations that differ between a library and the catalog.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*(feat|ft\.|with |from|remaster|version|edit|live|deluxe|explicit|video)[^\)\]]*[\)\]]?"#,
                                       with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s+-\s+(single|ep)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        return norm(t)
    }
}
