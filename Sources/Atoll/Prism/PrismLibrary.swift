import Foundation
import Metal
import SwiftUI
import os

/// Prism's compiled shaders: `scripts/shaders.sh` (and `build.sh`, into Contents/Resources) make Prism.metallib.
/// Found once, and every function is checked against the GPU before anything draws with it, so a missing or stale
/// library means the plain look, never a crash.
enum PrismLibrary {
    /// SwiftUI effects ([[stitchable]], visible functions).
    static let effectFunctions = ["prismFlutes", "prismSolid"]
    /// The ribbon stage's render pipeline.
    static let stageFunctions = ["ribbonVertex", "ribbonFragment"]
    static let fileName = "Prism.metallib"

    struct Loaded: @unchecked Sendable {
        let device: MTLDevice
        let library: MTLLibrary
        /// For SwiftUI's `layerEffect`/`colorEffect`: only from a metallib file — SwiftUI can't take a library built
        /// at run time, so a debug build compiled from source has the ribbons but not the SwiftUI material.
        let effects: ShaderLibrary?
        let origin: String
    }

    static let log = Logger(subsystem: "app.macflow", category: "prism")

    /// The library, or nil when Prism can't draw on this Mac.
    static let shared: Loaded? = {
        let env = ProcessInfo.processInfo.environment
        if env["ATOLL_METALLIB"] == "none" { return nil }
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        for url in candidates(environment: env) {
            if let loaded = load(url, device: device) { return loaded }
        }
        #if DEBUG
        // A debug run without scripts/shaders.sh: compile the stage from the repo's sources, so the ribbons still work.
        if let lib = try? compileSources(device: device), validate(lib, effects: false) {
            log.info("Prism: compiled from source (run scripts/shaders.sh for the SwiftUI material)")
            return Loaded(device: device, library: lib, effects: nil, origin: "source")
        }
        #endif
        log.error("Prism: no usable \(fileName, privacy: .public); Prism surfaces keep their plain look")
        return nil
    }()

    /// Where to look, in order: the app bundle, `ATOLL_METALLIB`, then (debug builds) the repo's build folder.
    static func candidates(environment env: [String: String], bundle: Bundle = .main) -> [URL] {
        var list: [URL] = []
        if let res = bundle.resourceURL { list.append(res.appendingPathComponent(fileName)) }
        if let path = env["ATOLL_METALLIB"], !path.isEmpty { list.append(URL(fileURLWithPath: path)) }
        #if DEBUG
        list.append(repo.appendingPathComponent("build").appendingPathComponent(fileName))
        #endif
        return list
    }

    static func load(_ url: URL, device: MTLDevice) -> Loaded? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let lib = try device.makeLibrary(URL: url)
            guard validate(lib, effects: true) else {
                log.error("Prism: \(url.path, privacy: .public) is missing functions; ignoring it")
                return nil
            }
            return Loaded(device: device, library: lib, effects: ShaderLibrary(url: url), origin: url.path)
        } catch {
            log.error("Prism: couldn't load \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Every function exists and is the kind its caller expects (SwiftUI asserts on anything else).
    static func validate(_ lib: MTLLibrary, effects: Bool) -> Bool {
        var want: [(String, MTLFunctionType)] = [("ribbonVertex", .vertex), ("ribbonFragment", .fragment)]
        if effects { want += effectFunctions.map { ($0, .visible) } }
        return want.allSatisfy { name, type in lib.makeFunction(name: name)?.functionType == type }
    }

    // MARK: Sources

    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let sourceFolder = repo.appendingPathComponent("Sources/Atoll/Prism/Shaders")

    /// The shader sources with their `#include "…"` lines expanded, for compiling at run time (tests, benchmarks,
    /// debug runs without the Metal toolchain).
    static func source(_ file: String) throws -> String {
        let text = try String(contentsOf: sourceFolder.appendingPathComponent(file), encoding: .utf8)
        return try text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#include \""), let name = t.split(separator: "\"").dropFirst().first else { return String(line) }
            return try source(String(name))
        }.joined(separator: "\n")
    }

    static func compileSources(device: MTLDevice) throws -> MTLLibrary {
        // One translation unit: the header guard keeps the shared optics single.
        let text = try source("Ribbon.metal") + "\n" + source("PrismFlutes.metal")
        let options = MTLCompileOptions()
        options.languageVersion = .version2_4
        return try device.makeLibrary(source: text, options: options)
    }

    // MARK: Prewarm

    /// macOS compiles a SwiftUI shader the first time it draws. On macOS 15 this does it ahead of time, off the main
    /// thread; on 14, `PrismWarmup` draws each effect once instead (in the island's 2.5 s prewarm).
    static func prewarm() {
        guard let loaded = shared else { return }
        PrismRenderer.warm()
        guard #available(macOS 15.0, *), let lib = loaded.effects else { return }
        let flutes = PrismEffect.flutes(lib, .island), solid = PrismEffect.solid(lib, .island)
        Task.detached(priority: .utility) {
            try? await flutes.compile(as: .layerEffect)
            try? await solid.compile(as: .colorEffect)
        }
    }
}
