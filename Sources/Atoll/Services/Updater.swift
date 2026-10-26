import AppKit
import CryptoKit
import Security

/// Updates from GitHub Releases. At launch and once a day Mac Flow asks GitHub for the newest release (just the
/// request: no identifiers, no account). When it's newer than this copy, the island offers it once, and the menu and
/// Settings › About keep offering it. Installing downloads the zipped app, checks it against the release's SHA-256, checks the
/// app inside is Mac Flow at that version and (when this copy is signed with a certificate) signed by the same one,
/// swaps it in place and relaunches.
///
/// Releases come from `.github/workflows/release.yml`, on every push to main that changes the app.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()
    nonisolated static let repository = "Bmorp/macFLOW"
    /// The release feed. The `--update-test` harness points it at a local file.
    nonisolated(unsafe) static var feed = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!

    struct Release: Equatable {
        let version: String
        let page: URL
        /// The app, zipped. The DMG next to it is for people; a zip needs no mounting.
        let archive: URL
        let checksum: URL
    }

    enum Status: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case installing(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var lastChecked = UserDefaults.standard.object(forKey: "updateLastChecked") as? Date

    private var timer: Timer?

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var available: Release? {
        if case .available(let r) = status { return r }
        return nil
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard Prefs.shared.autoUpdate else { return }
            Task { await self?.check(manual: false) }
        }
        // Hourly look at the clock; a check only once a day has passed.
        let t = Timer(timeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Prefs.shared.autoUpdate else { return }
                if let last = self.lastChecked, Date().timeIntervalSince(last) < 24 * 60 * 60 { return }
                Task { await self.check(manual: false) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// `manual` comes from a menu or Settings: failures are shown there, and the island stays quiet.
    func check(manual: Bool) async {
        switch status {
        case .checking, .installing: return
        default: break
        }
        status = .checking
        do {
            let release = try await Self.latest()
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: "updateLastChecked")
            guard let release, Self.isNewer(release.version, than: Self.currentVersion) else {
                status = .upToDate
                return
            }
            status = .available(release)
            if !manual, UserDefaults.standard.string(forKey: "updateOffered") != release.version {
                UserDefaults.standard.set(release.version, forKey: "updateOffered")
                IslandManager.shared.offerUpdate(release.version)
            }
        } catch {
            status = manual ? .failed("Couldn’t reach GitHub. Check your connection and try again.") : .idle
        }
    }

    func install() {
        guard let release = available else { return }
        let app = Bundle.main.bundleURL
        if let problem = Self.problemReplacing(app) {
            status = .failed(problem)
            return
        }
        status = .installing("Downloading Mac Flow \(release.version)…")
        Task.detached(priority: .userInitiated) {
            var work: URL?
            do {
                let staged = try await Self.prepare(release, replacing: app)
                work = staged.deletingLastPathComponent()
                await MainActor.run { Updater.shared.status = .installing("Installing…") }
                _ = try FileManager.default.replaceItemAt(app, withItemAt: staged, backupItemName: nil, options: .usingNewMetadataOnly)
                try? FileManager.default.removeItem(at: work!)
                await MainActor.run { Updater.shared.relaunch(app) }
            } catch {
                if let work { try? FileManager.default.removeItem(at: work) }
                #if DEBUG
                print("update failed: \(error)")
                #endif
                let message = (error as? UpdateError)?.message ?? "The update couldn’t be installed. Try again later."
                await MainActor.run { Updater.shared.status = .failed(message) }
            }
        }
    }

    /// Quits, and opens the new copy once this one has gone, so two islands never share the notch.
    private func relaunch(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                       "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: - Releases

    /// The newest published release, if it carries the zipped app and its checksum; nil when nothing is published yet.
    nonisolated static func latest() async throws -> Release? {
        var request = URLRequest(url: feed, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try ok(response)
        return parse(data)
    }

    nonisolated static func parse(_ data: Data) -> Release? {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: URL
            }
            let tag_name: String
            let html_url: URL
            let draft: Bool?
            let prerelease: Bool?
            let assets: [Asset]
        }
        guard let p = try? JSONDecoder().decode(Payload.self, from: data), p.draft != true, p.prerelease != true,
              let zip = p.assets.first(where: { $0.name.hasSuffix(".zip") }),
              let sum = p.assets.first(where: { $0.name == zip.name + ".sha256" }) else { return nil }
        let version = p.tag_name.hasPrefix("v") ? String(p.tag_name.dropFirst()) : p.tag_name
        return Release(version: version, page: p.html_url, archive: zip.browser_download_url, checksum: sum.browser_download_url)
    }

    /// "8.10.0" is newer than "8.9.2"; missing parts count as zero.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Installing

    struct UpdateError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// Why this copy can't replace itself, in words people can act on; nil when it can.
    static func problemReplacing(_ app: URL) -> String? {
        if app.path.contains("/AppTranslocation/") || app.path.hasPrefix("/Volumes/") {
            return "Move Mac Flow to your Applications folder, open it from there, then update."
        }
        let fm = FileManager.default
        if !fm.isWritableFile(atPath: app.deletingLastPathComponent().path) || !fm.isWritableFile(atPath: app.path) {
            return "Mac Flow can’t replace itself in this folder. Download the update from GitHub instead."
        }
        return nil
    }

    /// Downloads and checks the update, staged on the same volume as the app it replaces so the swap is a rename.
    nonisolated private static func prepare(_ release: Release, replacing app: URL) async throws -> URL {
        let fm = FileManager.default
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        do {
            let (download, response) = try await URLSession.shared.download(from: release.archive)
            try ok(response)
            let zip = work.appendingPathComponent("update.zip")
            try fm.moveItem(at: download, to: zip)

            let (sum, sumResponse) = try await URLSession.shared.data(from: release.checksum)
            try ok(sumResponse)
            guard let expected = String(decoding: sum, as: UTF8.self).split(whereSeparator: \.isWhitespace).first?.lowercased(),
                  try sha256(of: zip) == expected else { throw UpdateError("The download was damaged. Try again later.") }

            let unzipped = work.appendingPathComponent("unzipped", isDirectory: true)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, unzipped.path])
            guard let found = try fm.contentsOfDirectory(at: unzipped, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" })
            else { throw UpdateError("The download doesn’t contain Mac Flow.") }
            let staged = work.appendingPathComponent(app.lastPathComponent)
            try fm.moveItem(at: found, to: staged)

            try verify(staged, version: release.version)
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
            return staged
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    /// The same app, at the promised version, validly signed — and by the same certificate as this copy, if it has one.
    nonisolated private static func verify(_ app: URL, version: String) throws {
        guard let bundle = Bundle(url: app), bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version
        else { throw UpdateError("The download isn’t Mac Flow \(version).") }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode),
                                         ownRequirement()) == errSecSuccess
        else { throw UpdateError("The update isn’t signed like this copy of Mac Flow, so it wasn’t installed.") }
    }

    /// This copy's designated requirement when it's signed with a certificate. Nil when it's signed ad hoc: that
    /// requirement is its own hash, which no other build can meet.
    nonisolated private static func ownRequirement() -> SecRequirement? {
        var me: SecCode?, mine: SecStaticCode?, info: CFDictionary?, requirement: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
              SecCodeCopySigningInformation(mine, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certificates = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [Any], !certificates.isEmpty,
              SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess
        else { return nil }
        return requirement
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// GitHub answers over HTTP; the test harness reads files, which have no status.
    nonisolated private static func ok(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("The download failed. Try again later.")
        }
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("The update couldn’t be opened. Try again later.") }
    }
}
