import Foundation

/// Bayesian logistic regression with a Gaussian belief over its weights, updated one label at a time.
///
/// Each label is folded in with an online Laplace step: the new mean is the exact maximum of (Gaussian prior ×
/// this one weighted logistic likelihood) — it lies along Σx from the old mean, so finding it is a one-dimensional
/// Newton solve — and the covariance takes the curvature there as a rank-one (Sherman–Morrison) update. Keeping the
/// full covariance, not just its diagonal, is what lets a few reactions be blamed on the right thing: when you take
/// music while coding and wave it away while writing, the model learns that "coding" and "writing" pull apart rather
/// than smearing both into "music, sometimes". With a few dozen features that's a thousand multiply-adds per label:
/// microseconds, so it runs the instant feedback arrives.
///
/// `offset` is a fixed per-example term added to the score: the candidate's own hand-set confidence, so the weights
/// learn corrections to it rather than starting from nothing.
struct BayesLogit: Codable, Sendable, Equatable {
    var mean: [Double]
    /// Row-major d×d.
    var covariance: [Double]
    var priorMean: [Double]
    var priorVariance: [Double]
    /// Total weight of the labels learned from.
    var evidence: Double = 0
    var updated: Date

    init(priorMean: [Double], priorVariance: [Double], now: Date = Date()) {
        precondition(priorMean.count == priorVariance.count)
        let d = priorMean.count
        mean = priorMean
        self.priorMean = priorMean
        self.priorVariance = priorVariance
        covariance = [Double](repeating: 0, count: d * d)
        for i in 0..<d { covariance[i * d + i] = priorVariance[i] }
        updated = now
    }

    var dimension: Int { mean.count }

    /// How unsure one weight is.
    func variance(_ i: Int) -> Double { covariance[i * dimension + i] }

    /// Σx.
    private func spread(_ x: [Double]) -> [Double] {
        let d = dimension
        var out = [Double](repeating: 0, count: d)
        covariance.withUnsafeBufferPointer { c in
            for j in 0..<d where x[j] != 0 {
                let xj = x[j]
                for i in 0..<d { out[i] += c[i * d + j] * xj }
            }
        }
        return out
    }

    /// The score's belief: z = offset + w·x ~ N(mean, variance).
    func score(_ x: [Double], offset: Double = 0) -> (mean: Double, variance: Double) {
        guard x.count == dimension else { return (offset, 0) }
        let sx = spread(x)
        var m = offset, v = 0.0
        for i in 0..<dimension where x[i] != 0 {
            m += mean[i] * x[i]
            v += x[i] * sx[i]
        }
        return (m, max(0, v))
    }

    /// The chance of a yes, averaged over what Flow doesn't know yet (the probit approximation of the predictive).
    func probability(_ x: [Double], offset: Double = 0) -> Double {
        let (m, v) = score(x, offset: offset)
        return Self.sigmoid(m / (1 + .pi * v / 8).squareRoot())
    }

    /// One plausible score, drawn from the belief: what Thompson sampling decides with.
    func sample<G: RandomNumberGenerator>(_ x: [Double], offset: Double = 0, using rng: inout G) -> Double {
        let (m, v) = score(x, offset: offset)
        return m + v.squareRoot() * Self.gaussian(using: &rng)
    }

    /// Learns one label (1 = yes, 0 = no), counted `weight` times.
    mutating func learn(_ x: [Double], label y: Double, weight w: Double = 1, offset: Double = 0, at now: Date = Date()) {
        guard w > 0, x.count == dimension else { return }
        let sx = spread(x)
        var s = offset, v = 0.0
        for i in 0..<dimension where x[i] != 0 {
            s += mean[i] * x[i]
            v += x[i] * sx[i]
        }
        guard v > 0 else { return }
        // α solves α = w·(y − σ(s + α·v)); Newton from 0 converges in a handful of steps.
        var a = 0.0
        for _ in 0..<8 {
            let p = Self.sigmoid(s + a * v)
            let g = a - w * (y - p)
            let dg = 1 + w * p * (1 - p) * v
            let step = g / dg
            a -= step
            if abs(step) < 1e-9 { break }
        }
        for i in 0..<dimension { mean[i] += a * sx[i] }
        let p = Self.sigmoid(s + a * v)
        let c = w * p * (1 - p)
        // (Σ⁻¹ + c·xxᵀ)⁻¹ = Σ − c/(1 + c·v) · (Σx)(Σx)ᵀ
        let k = c / (1 + c * v)
        let d = dimension
        covariance.withUnsafeMutableBufferPointer { cov in
            for i in 0..<d where sx[i] != 0 {
                let si = sx[i] * k
                for j in 0..<d { cov[i * d + j] -= si * sx[j] }
            }
        }
        evidence += w
        updated = now
    }

    /// Lets old certainty fade: the belief relaxes back toward the prior with `halfLife`, so a preference from months
    /// ago is held more loosely and gets checked again. The mean drifts back far more slowly than the certainty.
    mutating func relax(to now: Date, halfLife: TimeInterval) {
        let dt = now.timeIntervalSince(updated)
        guard dt > 3600, halfLife > 0 else { return }
        let k = pow(0.5, dt / halfLife)
        let km = pow(0.5, dt / (halfLife * 3))
        let d = dimension
        for i in 0..<d {
            mean[i] = priorMean[i] + (mean[i] - priorMean[i]) * km
            for j in 0..<d {
                let prior = i == j ? priorVariance[i] : 0
                covariance[i * d + j] = prior + (covariance[i * d + j] - prior) * k
            }
        }
        evidence *= k
        updated = now
    }

    /// Back to the prior.
    mutating func forget() {
        self = BayesLogit(priorMean: priorMean, priorVariance: priorVariance, now: updated)
    }

    // MARK: Refitting

    /// One label, kept so the belief can be refitted from scratch.
    struct Example: Codable, Sendable, Equatable {
        var x: [Double]
        var y: Double
        var weight: Double
        var offset: Double
        var at: Date
    }

    /// The exact Laplace posterior over every kept label at once: Newton's method to the most likely weights under
    /// the prior, then the curvature there as the covariance. A single pass of online updates under-learns when
    /// labels arrive in an unlucky order (each is linearised once, at the belief of its moment); the refit doesn't.
    /// Old labels count less (`halfLife`). A few milliseconds for a few hundred labels, so it runs off the main thread.
    static func fit(priorMean: [Double], priorVariance: [Double], examples: [Example], now: Date, halfLife: TimeInterval,
                    start: [Double]? = nil) -> BayesLogit {
        var model = BayesLogit(priorMean: priorMean, priorVariance: priorVariance, now: now)
        let d = priorMean.count
        let precision = priorVariance.map { 1 / max($0, 1e-6) }
        let weights = examples.map { e in e.weight * (halfLife > 0 ? pow(0.5, max(0, now.timeIntervalSince(e.at)) / halfLife) : 1) }
        guard !examples.isEmpty else { return model }
        var theta = start?.count == d ? start! : priorMean
        var hessian = [Double](repeating: 0, count: d * d)
        for _ in 0..<12 {
            var grad = (0..<d).map { -precision[$0] * (theta[$0] - priorMean[$0]) }
            hessian = [Double](repeating: 0, count: d * d)
            for i in 0..<d { hessian[i * d + i] = precision[i] }
            for (e, w) in zip(examples, weights) where w > 1e-4 && e.x.count == d {
                var z = e.offset
                for i in 0..<d where e.x[i] != 0 { z += theta[i] * e.x[i] }
                let p = sigmoid(z)
                let r = w * (e.y - p), c = w * p * (1 - p)
                for i in 0..<d where e.x[i] != 0 {
                    grad[i] += r * e.x[i]
                    let ci = c * e.x[i]
                    for j in 0..<d where e.x[j] != 0 { hessian[i * d + j] += ci * e.x[j] }
                }
            }
            guard let step = Cholesky(hessian, d)?.solve(grad) else { break }
            var size = 0.0
            for i in 0..<d { theta[i] += step[i]; size = max(size, abs(step[i])) }
            if size < 1e-6 { break }
        }
        guard let chol = Cholesky(hessian, d) else { return model }
        model.mean = theta
        model.covariance = chol.inverse()
        model.evidence = weights.reduce(0, +)
        return model
    }
}

/// Cholesky factorisation of a small symmetric positive-definite matrix (row-major), for the refit.
private struct Cholesky {
    let l: [Double]
    let d: Int

    init?(_ a: [Double], _ d: Int) {
        var l = [Double](repeating: 0, count: d * d)
        for i in 0..<d {
            for j in 0...i {
                var sum = a[i * d + j]
                for k in 0..<j { sum -= l[i * d + k] * l[j * d + k] }
                if i == j {
                    guard sum > 1e-12 else { return nil }
                    l[i * d + i] = sum.squareRoot()
                } else {
                    l[i * d + j] = sum / l[j * d + j]
                }
            }
        }
        self.l = l
        self.d = d
    }

    /// A⁻¹b.
    func solve(_ b: [Double]) -> [Double] {
        var y = b
        for i in 0..<d {
            for k in 0..<i { y[i] -= l[i * d + k] * y[k] }
            y[i] /= l[i * d + i]
        }
        var x = y
        for i in stride(from: d - 1, through: 0, by: -1) {
            for k in (i + 1)..<d { x[i] -= l[k * d + i] * x[k] }
            x[i] /= l[i * d + i]
        }
        return x
    }

    func inverse() -> [Double] {
        var out = [Double](repeating: 0, count: d * d)
        for j in 0..<d {
            var e = [Double](repeating: 0, count: d)
            e[j] = 1
            let col = solve(e)
            for i in 0..<d { out[i * d + j] = col[i] }
        }
        return out
    }
}

extension BayesLogit {

    // MARK: Maths

    static func sigmoid(_ z: Double) -> Double {
        z >= 0 ? 1 / (1 + exp(-z)) : exp(z) / (1 + exp(z))
    }

    static func logit(_ p: Double) -> Double {
        let q = min(max(p, 1e-6), 1 - 1e-6)
        return log(q / (1 - q))
    }

    /// Standard normal CDF.
    static func phi(_ x: Double) -> Double { 0.5 * erfc(-x / 2.squareRoot()) }

    /// A standard normal draw (Box–Muller).
    static func gaussian<G: RandomNumberGenerator>(using rng: inout G) -> Double {
        let u1 = max(Double.random(in: 0..<1, using: &rng), 1e-12)
        let u2 = Double.random(in: 0..<1, using: &rng)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// A small, seedable generator: the same seed gives the same draws, so simulations and tests are repeatable.
struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
