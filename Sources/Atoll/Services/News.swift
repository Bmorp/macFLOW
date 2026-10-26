import Foundation
import SwiftUI

/// The Brief: headlines from feeds you choose, ranked on this Mac by what you work on and read (your interest vector,
/// from Flow's memory). The only network requests are to those feeds — plain fetches, no cookies, nothing about you.
struct NewsFeed: Codable, Identifiable, Equatable {
    var id: String { url.absoluteString }
    let name: String
    let url: URL
    var on: Bool

    static let defaults: [NewsFeed] = [
        NewsFeed(name: "Hacker News", url: URL(string: "https://hnrss.org/frontpage")!, on: true),
        NewsFeed(name: "The Verge", url: URL(string: "https://www.theverge.com/rss/index.xml")!, on: true),
        NewsFeed(name: "Apple Newsroom", url: URL(string: "https://www.apple.com/newsroom/rss-feed.rss")!, on: true),
        NewsFeed(name: "Ars Technica", url: URL(string: "https://feeds.arstechnica.com/arstechnica/index")!, on: false),
        NewsFeed(name: "BBC Technology", url: URL(string: "https://feeds.bbci.co.uk/news/technology/rss.xml")!, on: false),
        NewsFeed(name: "BBC World", url: URL(string: "https://feeds.bbci.co.uk/news/world/rss.xml")!, on: false),
    ]
}

struct NewsItem: Codable, Identifiable, Equatable {
    var id: String { link.absoluteString }
    let title: String
    let link: URL
    let source: String
    let date: Date
    let summary: String
    /// How close it is to your interests (cosine, −1…1); 0 until ranked.
    var relevance: Float = 0

    var forYou: Bool { relevance >= 0.38 }
}

@MainActor
final class NewsStore: ObservableObject {
    static let shared = NewsStore()
    @Published private(set) var items: [NewsItem] = []
    @Published private(set) var feeds: [NewsFeed]
    @Published private(set) var fetchedAt = Date.distantPast
    @Published private(set) var fetching = false
    private var timer: Timer?
    private static let feedsFile = "news-feeds.json"
    private static let itemsFile = "news.json"

    init() {
        feeds = Storage.load([NewsFeed].self, from: Self.feedsFile) ?? NewsFeed.defaults
        items = Storage.load([NewsItem].self, from: Self.itemsFile) ?? []
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 45 * 60, repeats: true) { _ in MainActor.assumeIsolated { NewsStore.shared.refresh() } }
        t.tolerance = 300
        RunLoop.main.add(t, forMode: .common)
        timer = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { NewsStore.shared.refresh() }
    }

    /// The top of the Brief: for you first, then newest.
    var brief: [NewsItem] {
        items.sorted { a, b in a.forYou != b.forYou ? a.forYou : a.date > b.date }
    }

    func setFeed(_ feed: NewsFeed, on: Bool) {
        guard let i = feeds.firstIndex(where: { $0.id == feed.id }) else { return }
        feeds[i].on = on
        Storage.save(feeds, to: Self.feedsFile)
        refresh(force: true)
    }

    func addFeed(_ text: String) -> Bool {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(url.scheme ?? ""),
              !feeds.contains(where: { $0.url == url }) else { return false }
        feeds.append(NewsFeed(name: url.host?.replacingOccurrences(of: "www.", with: "") ?? "Feed", url: url, on: true))
        Storage.save(feeds, to: Self.feedsFile)
        refresh(force: true)
        return true
    }

    func removeFeed(_ feed: NewsFeed) {
        feeds.removeAll { $0.id == feed.id }
        Storage.save(feeds, to: Self.feedsFile)
        items.removeAll { $0.source == feed.name }
    }

    /// Fetches the feeds that are on (if it's been a while), then ranks everything by your interests.
    func refresh(force: Bool = false) {
        guard Prefs.shared.newsEnabled, !fetching, force || Date().timeIntervalSince(fetchedAt) > 15 * 60 else { return }
        let active = feeds.filter(\.on)
        guard !active.isEmpty else { items = []; return }
        fetching = true
        Task { @MainActor in
            var all: [NewsItem] = []
            await withTaskGroup(of: [NewsItem].self) { group in
                for feed in active { group.addTask { await Self.fetch(feed) } }
                for await list in group { all += list }
            }
            let cutoff = Date().addingTimeInterval(-2 * 86_400)
            var fresh = Array(Dictionary(all.filter { $0.date > cutoff }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }).values)
            fresh.sort { $0.date > $1.date }
            fresh = Array(fresh.prefix(80))
            self.items = fresh
            self.fetchedAt = Date()
            self.fetching = false
            self.rank()
        }
    }

    /// On this Mac: each headline's closeness to your interest vector.
    private func rank() {
        let texts = items.map { "\($0.title). \($0.summary.prefix(160))" }
        Memory.shared.interest { vector in
            guard let vector else {
                DispatchQueue.main.async { MainActor.assumeIsolated { Storage.save(NewsStore.shared.items, to: Self.itemsFile) } }
                return
            }
            Memory.shared.closeness(of: texts, to: vector) { scores in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let me = NewsStore.shared
                        guard me.items.count == scores.count else { return }
                        for i in me.items.indices { me.items[i].relevance = scores[i] }
                        Storage.save(me.items, to: Self.itemsFile)
                    }
                }
            }
        }
    }

    nonisolated static func fetch(_ feed: NewsFeed) async -> [NewsItem] {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 12
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpAdditionalHeaders = ["User-Agent": "MacFlow/7 (+news brief)"]
        let session = URLSession(configuration: config)
        guard let (data, response) = try? await session.data(from: feed.url),
              (response as? HTTPURLResponse)?.statusCode ?? 0 < 400 else { return [] }
        return FeedParser.parse(data, source: feed.name)
    }

    #if DEBUG
    func debugSet(_ list: [NewsItem]) { items = list }
    #endif
}

/// RSS 2.0 and Atom, enough for headlines: title, link, date, a line of summary.
final class FeedParser: NSObject, XMLParserDelegate {
    private var items: [NewsItem] = []
    private let source: String
    private var inItem = false
    private var element = ""
    private var title = "", link = "", date = "", summary = ""

    init(source: String) { self.source = source }

    static func parse(_ data: Data, source: String) -> [NewsItem] {
        let p = FeedParser(source: source)
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let n = name.lowercased()
        if n == "item" || n == "entry" {
            inItem = true
            title = ""; link = ""; date = ""; summary = ""
        }
        element = n
        if inItem, n == "link", let href = attributes["href"], link.isEmpty, (attributes["rel"] ?? "alternate") == "alternate" { link = href }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }

    func parser(_ parser: XMLParser, foundCDATA data: Data) { append(String(decoding: data, as: UTF8.self)) }

    private func append(_ s: String) {
        guard inItem else { return }
        switch element {
        case "title": title += s
        case "link": link += s
        case "pubdate", "published", "updated", "dc:date": if date.count < 64 { date += s }
        case "description", "summary", "content:encoded", "content": if summary.count < 600 { summary += s }
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let n = name.lowercased()
        if n == "item" || n == "entry" {
            inItem = false
            let t = Self.clean(title)
            if !t.isEmpty, let url = URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) {
                items.append(NewsItem(title: t, link: url, source: source, date: Self.date(date) ?? Date(), summary: Self.clean(summary)))
            }
        }
        element = ""
    }

    /// Strips tags and entities, collapses space.
    static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (e, r) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "’"), ("&apos;", "’"), ("&nbsp;", " "), ("&#8217;", "’"), ("&#8216;", "‘"), ("&#8220;", "“"), ("&#8221;", "”")] {
            t = t.replacingOccurrences(of: e, with: r)
        }
        return t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func date(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = ISO8601DateFormatter().date(from: t) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ"] {
            f.dateFormat = format
            if let d = f.date(from: t) { return d }
        }
        return nil
    }
}
