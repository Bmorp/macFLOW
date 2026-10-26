import AppKit

@main
enum AtollMain {
    #if DEBUG || ATOLL_PROBE
    @MainActor static var probe: PerfProbe?
    @MainActor static var transitions: TransitionCapture?
    #endif

    @MainActor
    static func main() {
        let app = NSApplication.shared
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i + 1 {
            app.setActivationPolicy(.accessory)
            SnapshotHarness.run(outDir: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--motion"), CommandLine.arguments.count > i + 1 {
            app.setActivationPolicy(.accessory)
            MotionHarness.run(outDir: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--standby"), CommandLine.arguments.count > i + 1 {
            app.setActivationPolicy(.accessory)
            SurfaceHarness.runStandBy(outDir: CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--surfaces"), CommandLine.arguments.count > i + 1 {
            app.setActivationPolicy(.accessory)
            SurfaceHarness.run(outDir: CommandLine.arguments[i + 1])
            return
        }
        #endif
        let delegate = AppDelegate()
        app.delegate = delegate
        #if DEBUG || ATOLL_PROBE
        if let i = CommandLine.arguments.firstIndex(of: "--perf"), CommandLine.arguments.count > i + 1 {
            probe = PerfProbe(outDir: CommandLine.arguments[i + 1])
            probe?.start()
        }
        if let i = CommandLine.arguments.firstIndex(of: "--transitions"), CommandLine.arguments.count > i + 1 {
            transitions = TransitionCapture(outDir: CommandLine.arguments[i + 1])
            transitions?.start()
        }
        #endif
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--standby-check"), CommandLine.arguments.count > i + 1 {
            LiveCapture.standByCheck(outDir: CommandLine.arguments[i + 1])
        }
        if CommandLine.arguments.contains("--page-check") { LiveCapture.pageCheck() }
        if CommandLine.arguments.contains("--claude-check") { LiveCapture.claudeCheck() }
        if CommandLine.arguments.contains("--brain-check") { LiveCapture.brainCheck() }
        if let i = CommandLine.arguments.firstIndex(of: "--dock-check"), CommandLine.arguments.count > i + 1 {
            LiveCapture.dockCheck(outDir: CommandLine.arguments[i + 1])
        }
        if CommandLine.arguments.contains("--art-check") { ArtCheck.schedule() }
        if CommandLine.arguments.contains("--hover-test") { HoverTest.schedule() }
        if let i = CommandLine.arguments.firstIndex(of: "--dim-check"), CommandLine.arguments.count > i + 1 {
            // Debug: start a focus block, save the dimming window (Mac Flow's own), stop. Dims the screen ~2 s.
            let out = CommandLine.arguments[i + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                FocusTimer.shared.start(minutes: 1, label: "Dim check")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    if let w = NSApp.windows.first(where: { $0.level == .floating && $0.ignoresMouseEvents && $0.isVisible }),
                       let view = w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                        print("dim check: window \(Int(w.frame.width))x\(Int(w.frame.height)) alpha \(w.alphaValue) · hole \(FocusDimmer.shared.debugHole.map { "\($0)" } ?? "none") · front \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
                    } else {
                        print("dim check: no dimming window")
                    }
                    FocusTimer.shared.stop()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { exit(0) }
                }
            }
        }
        if CommandLine.arguments.contains("--file-check") { FileCheck.schedule() }
        if CommandLine.arguments.contains("--agent-check") { AgentCheck.schedule() }
        if CommandLine.arguments.contains("--art-bench") { ArtBench.schedule() }
        if let i = CommandLine.arguments.firstIndex(of: "--settings-check"), CommandLine.arguments.count > i + 1 {
            SettingsCheck.schedule(outDir: CommandLine.arguments[i + 1])
        }
        if let i = CommandLine.arguments.firstIndex(of: "--live-capture"), CommandLine.arguments.count > i + 1 {
            LiveCapture.schedule(outDir: CommandLine.arguments[i + 1])
        }
        #endif
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
