#if DEBUG
import AppKit

/// Debug: opens Settings once the app is running and saves each page — drawn from Atoll's own view, nothing else.
@MainActor
enum SettingsCheck {
    static func schedule(outDir: String) {
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        // The menu bar icon, as a template image would draw in both menu bars.
        for (name, color) in [("menubar-light", NSColor.black), ("menubar-dark", NSColor.white)] {
            let img = Brand.menuBarImage()
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 156, pixelsHigh: 96, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            // Tint the template on its own, then lay it on the bar colour.
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r)
                color.setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            (color == .white ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(x: 0, y: 0, width: 156, height: 96).fill()
            tinted.draw(in: NSRect(x: 0, y: 0, width: 156, height: 96))
            NSGraphicsContext.restoreGraphicsState()
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
        }
        let pages: [SettingsPage] = [.permissions, .brain]
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            WindowManager.shared.showSettings(page: .overview)
            for (i, page) in pages.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 * Double(i + 1)) {
                    SettingsRouter.shared.page = page
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        guard let view = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.resizable) && $0.frame.width >= 800 })?.contentView?.superview,
                              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(outDir)/settings-\(page.rawValue).png"))
                        if i == pages.count - 1 { print("settings check done"); exit(0) }
                    }
                }
            }
        }
    }
}
#endif

#if DEBUG
/// Debug: reports whether the live track's cover and colour field arrived.
@MainActor
enum ArtCheck {
    static func schedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            let m = NowPlayingModel.shared
            print("art check: \(m.title) — \(m.artist) · source \(m.source?.name ?? "none") · playing \(m.isPlaying) · artwork \(m.artwork.map { "\(Int($0.size.width))px" } ?? "missing") · field \(m.palette == nil ? "missing" : "ready")")
            exit(0)
        }
    }
}
#endif

#if DEBUG
/// Debug: runs a file search and reports what came back, and when.
@MainActor
enum FileCheck {
    static func schedule() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            let start = Date()
            FileSearch.shared.search("design")
            var reported = false
            for delay in [0.3, 0.6, 1.0, 1.5, 2.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    let hits = FileSearch.shared.hits
                    print(String(format: "file check +%.1fs: %d hits %@", Date().timeIntervalSince(start), hits.count, hits.prefix(3).map(\.name).joined(separator: ", ")))
                    if delay == 2.5 { exit(0) }
                    if !hits.isEmpty, !reported { reported = true }
                }
            }
        }
    }
}
#endif

#if DEBUG
/// Debug: talks to the Brain agent on the real on-device model in dry-run mode (tools record, never act).
@MainActor
enum AgentCheck {
    static let prompts = [
        "What did I get done today?",
        "Start a 25 minute focus timer and play AP Dhillon",
        "Turn the volume down to 30",
        "Open workflowsurvey",
        "Remember that I like lo-fi while writing",
        "Remind me to call Sam at 5pm",
        "Pause the music",
        "Explain how Swift actors prevent data races",
    ]

    static func schedule() {
        BrainAgent.dryRun = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { Task { @MainActor in await run() } }
    }

    static func run() async {
        let agent = BrainAgent.shared
        for p in prompts {
            let start = Date()
            let before = agent.messages.count
            agent.send(p)
            while agent.thinking { try? await Task.sleep(nanoseconds: 100_000_000) }
            let new = agent.messages.dropFirst(before)
            print(String(format: "\n» %@   (%.1fs)", p, Date().timeIntervalSince(start)))
            for m in new where m.role != .you {
                print(m.role == .action ? "  ⚙︎ \(m.text)" : "  ✦ \(m.text)")
            }
        }
        exit(0)
    }
}
#endif

#if DEBUG
/// Debug: the cover path for songs from Apple Music — catalog (cold), then this Mac's cover cache.
@MainActor
enum ArtBench {
    static let songs: [(String, String, String)] = [
        ("Kareeb", "Bharat Chauhan", "Uns"),
        ("Alag Aasmaan", "Anuv Jain", "Alag Aasmaan - Single"),
    ]

    static func schedule() {
        Task { @MainActor in
            for (t, a, al) in songs {
                let key = ArtworkStore.key(title: t, artist: a, album: al)
                var start = Date()
                let img = await ArtworkStore.catalog(title: t, artist: a, album: al, key: key)
                let cold = Int(Date().timeIntervalSince(start) * 1000)
                if let img { ArtworkStore.store(img, for: key) }
                try? await Task.sleep(nanoseconds: 300_000_000)   // let the disk write land
                start = Date()
                let disk = ArtworkStore.fromDisk(key)
                let warm = Int(Date().timeIntervalSince(start) * 1000)
                print("art bench: \(t) — \(a): catalog \(img == nil ? "no match" : "\(Int(img!.size.width))px") in \(cold) ms · from cache \(disk == nil ? "missing" : "ok") in \(warm) ms")
            }
            exit(0)
        }
    }
}
#endif
