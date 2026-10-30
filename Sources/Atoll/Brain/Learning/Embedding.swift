import Foundation
import NaturalLanguage

/// Text as a direction: Apple's on-device sentence embedding when it's there, a hashed bag of words and letter
/// trigrams when it isn't (and in tests, where the same words must always give the same vector). Unit length, so a
/// dot product is the cosine. Thread-safe: the system embedding is used from one queue only.
final class TextEmbedder: @unchecked Sendable {
    static let shared = TextEmbedder()

    private let queue = DispatchQueue(label: "atoll.brain.embed", qos: .utility)
    private let useSystem: Bool
    private lazy var system: NLEmbedding? = useSystem ? NLEmbedding.sentenceEmbedding(for: .english) : nil
    private var cache: [String: [Float]] = [:]

    /// `system: false` gives the hashed embedding only: deterministic, for tests.
    init(system: Bool = true) { useSystem = system }

    func vector(_ text: String) -> [Float]? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        return queue.sync {
            if let hit = cache[t] { return hit }
            let v = system?.vector(for: t).map { Self.normalised($0.map(Float.init)) } ?? Self.hashed(t)
            if cache.count > 2000 { cache.removeAll(keepingCapacity: true) }
            cache[t] = v
            return v
        }
    }

    /// Words and letter trigrams hashed into a fixed number of slots: texts sharing words point the same way.
    static func hashed(_ text: String, dimensions: Int = 256) -> [Float] {
        var v = [Float](repeating: 0, count: dimensions)
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        for w in words {
            v[Int(ContextFeatures.stableHash("w:" + w) % UInt64(dimensions))] += 1
            let chars = Array("^" + w + "$")
            if chars.count >= 3 {
                for i in 0...(chars.count - 3) {
                    v[Int(ContextFeatures.stableHash("t:" + String(chars[i..<i + 3])) % UInt64(dimensions))] += 0.35
                }
            }
        }
        return normalised(v)
    }

    static func normalised(_ v: [Float]) -> [Float] {
        let n = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return n > 0 ? v.map { $0 / n } : v
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i] }
        return dot
    }
}
