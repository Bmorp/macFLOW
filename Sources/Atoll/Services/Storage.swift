import Foundation
import os

/// Small JSON persistence in ~/Library/Application Support/Atoll.
enum Storage {
    /// Debug snapshots must never overwrite real user data.
    static var readOnly = false

    /// Encoding and writing happen here, never on the main thread (the clipboard history alone can be a
    /// megabyte of JSON, rewritten on every copy). Only the newest pending save of a file is written.
    private static let writer = DispatchQueue(label: "atoll.storage", qos: .utility)
    private static let generations = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("Atoll", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        let url = directory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        guard !readOnly else { return }
        let generation = generations.withLock { g -> Int in
            g[name, default: 0] += 1
            return g[name]!
        }
        let box = UncheckedBox(value)
        writer.async {
            // A newer save of the same file is already queued: skip this one.
            guard generations.withLock({ $0[name] }) == generation else { return }
            let url = directory.appendingPathComponent(name)
            guard let data = try? JSONEncoder().encode(box.value) else { return }
            try? data.write(to: url, options: [.atomic])
            // Clipboard and notes can be personal — keep them owner-only.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Waits for pending saves (at quit).
    static func flush() { writer.sync {} }

    /// Saved values are value types (arrays of structs), copied at the call; this only carries one across.
    private struct UncheckedBox<V>: @unchecked Sendable { let value: V; init(_ v: V) { value = v } }
}
