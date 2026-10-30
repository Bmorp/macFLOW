import os

/// Instruments-visible marks for the island's motion, and (in probe builds) counters the probe reads.
/// Signposts cost almost nothing unless Instruments is recording, so they stay in shipping builds.
enum IslandTrace {
    static let signposter = OSSignposter(subsystem: "com.bmorp.macflow", category: "Island")

    #if DEBUG || ATOLL_PROBE
    /// How many times an island root view (`IslandView`, the engine's hosts) evaluated its body.
    /// Each transition should cost one or two; an animation frame should cost none.
    @MainActor static var rootBodies = 0
    #endif

    /// Called from an island root's `body`.
    @MainActor @inline(__always) static func countBody() {
        #if DEBUG || ATOLL_PROBE
        rootBodies &+= 1
        #endif
    }
}
