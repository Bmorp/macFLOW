import CoreGraphics
import Foundation

/// One stretch of a column that the glyphs cover, top to foot, in points (y down).
struct RibbonRun: Equatable, Sendable {
    var top: Float
    var foot: Float
    var mid: Float { (top + foot) * 0.5 }
    var length: Float { foot - top }
    /// A run of no length at `y`: where a new run grows from, or an old one collapses into.
    static func point(_ y: Float) -> RibbonRun { RibbonRun(top: y, foot: y) }
}

/// Numerals as glass strips: column `i` is centred at (i + 0.5) · pitch on the canvas, and holds up to four runs.
struct RibbonColumns: Equatable, Sendable {
    var pitch: Float
    var runs: [Int: [RibbonRun]]
    /// The outline's top and foot, for the light's ramp.
    var top: Float
    var foot: Float

    static let empty = RibbonColumns(pitch: 1, runs: [:], top: 0, foot: 1)
    var stripCount: Int { runs.values.reduce(0) { $0 + $1.count } }
}

/// One strip as the GPU draws it (matches `Strip` in Ribbon.metal): where its run was, where it's going, when it
/// starts to move.
struct RibbonStrip: Equatable, Sendable {
    var x: Float
    var y0a: Float, y1a: Float
    var y0b: Float, y1b: Float
    var delay: Float
    /// 0: the old run, fading out; 1: the new run, fading in (Reduce Motion); 2: a spring from a to b.
    var phase: Float
    var index: Float
}

/// The spring every run end rides: underdamped a touch, so strips settle like ribbon, not like a counter. Ribbon.metal
/// evaluates the same closed form.
enum RibbonSpring {
    static let response: Float = 0.5
    static let damping: Float = 0.8
    static var omega: Float { 2 * .pi / response }
    /// The foot of each run follows its top by this much, so a strip rolls rather than slides.
    static let lag: Float = 0.035
    /// Columns start one after another, left to right, `stagger` apart, but a whole change sweeps in at most `sweep`.
    static let stagger: Float = 0.008
    static let sweep: Float = 0.45
    static let crossFade: Float = 0.2

    static func progress(_ t: Float, omega: Float = omega, zeta: Float = damping) -> Float {
        guard t > 0 else { return 0 }
        let x: Float
        if zeta < 1 {
            let wd = omega * (1 - zeta * zeta).squareRoot()
            x = exp(-zeta * omega * t) * (cos(wd * t) + (zeta * omega / wd) * sin(wd * t))
        } else {
            x = (1 + omega * t) * exp(-omega * t)
        }
        return 1 - x
    }

    /// When the spring is within 0.2 % of rest (sub-pixel on any run).
    static var settle: Float {
        let z = damping
        return -log(0.002 * (1 - z * z).squareRoot()) / (z * omega)
    }
}

enum RibbonLayout {
    static let maxRuns = 4

    struct Edge { var x0: Float, y0: Float, x1: Float, y1: Float }

    // MARK: Outline → runs

    /// The outline as straight edges (curves flattened finely enough for sub-pixel run ends).
    static func edges(_ path: CGPath) -> [Edge] {
        var out: [Edge] = []
        var start = CGPoint.zero, last = CGPoint.zero
        func line(_ p: CGPoint) {
            if p != last { out.append(Edge(x0: Float(last.x), y0: Float(last.y), x1: Float(p.x), y1: Float(p.y))) }
            last = p
        }
        func steps(_ pts: [CGPoint]) -> Int {
            var len: CGFloat = 0
            for i in 1..<pts.count { len += hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y) }
            return max(2, min(32, Int(len / 3)))
        }
        path.applyWithBlock { el in
            let e = el.pointee
            switch e.type {
            case .moveToPoint:
                if last != start { line(start) }
                start = e.points[0]; last = start
            case .addLineToPoint:
                line(e.points[0])
            case .addQuadCurveToPoint:
                let p0 = last, c = e.points[0], p1 = e.points[1]
                let n = steps([p0, c, p1])
                for i in 1...n {
                    let t = CGFloat(i) / CGFloat(n), u = 1 - t
                    line(CGPoint(x: u * u * p0.x + 2 * u * t * c.x + t * t * p1.x, y: u * u * p0.y + 2 * u * t * c.y + t * t * p1.y))
                }
            case .addCurveToPoint:
                let p0 = last, c0 = e.points[0], c1 = e.points[1], p1 = e.points[2]
                let n = steps([p0, c0, c1, p1])
                for i in 1...n {
                    let t = CGFloat(i) / CGFloat(n), u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    line(CGPoint(x: a * p0.x + b * c0.x + c * c1.x + d * p1.x, y: a * p0.y + b * c0.y + c * c1.y + d * p1.y))
                }
            case .closeSubpath:
                line(start)
            @unknown default:
                break
            }
        }
        if last != start { line(start) }
        return out
    }

    /// Where a vertical line at `x` is inside the outline (non-zero winding, as glyphs are filled), as runs.
    static func runs(_ edges: [Edge], x: Float) -> [RibbonRun] {
        var hits: [(y: Float, dir: Int)] = []
        for e in edges where (e.x0 <= x) != (e.x1 <= x) {
            let y = e.y0 + (x - e.x0) * (e.y1 - e.y0) / (e.x1 - e.x0)
            hits.append((y, e.x1 > e.x0 ? 1 : -1))
        }
        hits.sort { $0.y < $1.y }
        var out: [RibbonRun] = []
        var winding = 0, top: Float = 0
        for h in hits {
            let was = winding
            winding += h.dir
            if was == 0, winding != 0 { top = h.y }
            if was != 0, winding == 0 { out.append(RibbonRun(top: top, foot: h.y)) }
        }
        return tidy(out)
    }

    /// Drops slivers, closes hairline gaps, and keeps at most four runs (closing the smallest gaps first).
    static func tidy(_ input: [RibbonRun], minimum: Float = 0.5) -> [RibbonRun] {
        var runs: [RibbonRun] = []
        for r in input where r.length >= minimum {
            if let last = runs.last, r.top - last.foot < minimum { runs[runs.count - 1].foot = max(last.foot, r.foot) } else { runs.append(r) }
        }
        while runs.count > maxRuns {
            var best = 0
            for i in 0..<(runs.count - 1) where runs[i + 1].top - runs[i].foot < runs[best + 1].top - runs[best].foot { best = i }
            runs[best].foot = runs[best + 1].foot
            runs.remove(at: best + 1)
        }
        return runs
    }

    /// The outline sampled at the centre of every column it reaches.
    static func columns(_ path: CGPath, pitch: CGFloat) -> RibbonColumns {
        let box = path.boundingBoxOfPath
        guard pitch > 0, !box.isNull, !box.isEmpty else { return .empty }
        let p = Float(pitch)
        let all = edges(path)
        // Bucket edges by the columns they span, so each column only tests its own.
        let first = Int(floor(Float(box.minX) / p)), last = Int(floor(Float(box.maxX) / p))
        var buckets = [[Edge]](repeating: [], count: last - first + 1)
        for e in all {
            let lo = max(first, Int(floor(min(e.x0, e.x1) / p))), hi = min(last, Int(floor(max(e.x0, e.x1) / p)))
            guard lo <= hi else { continue }
            for c in lo...hi { buckets[c - first].append(e) }
        }
        var out: [Int: [RibbonRun]] = [:]
        for c in first...last {
            let r = runs(buckets[c - first], x: (Float(c) + 0.5) * p)
            if !r.isEmpty { out[c] = r }
        }
        return RibbonColumns(pitch: p, runs: out, top: Float(box.minY), foot: Float(box.maxY))
    }

    // MARK: Morph

    /// Pairs the runs of one column before and after a change, in order. When the counts differ, the pairing is the
    /// one that moves least; a run with no partner grows out of (or collapses into) the nearest run's midpoint on the
    /// other side. In a column that was (or becomes) empty, runs unroll down from their top (or roll up into it), as
    /// ribbon does.
    static func match(_ a: [RibbonRun], _ b: [RibbonRun]) -> [(from: RibbonRun, to: RibbonRun)] {
        if a.isEmpty { return b.map { (.point($0.top), $0) } }
        if b.isEmpty { return a.map { ($0, .point($0.top)) } }
        if a.count > b.count { return match(b, a).map { ($0.to, $0.from) } }
        // a.count ≤ b.count: choose which runs of b the runs of a become.
        var best: [Int] = [], bestCost = Float.infinity
        func cost(_ x: RibbonRun, _ y: RibbonRun) -> Float { abs(x.mid - y.mid) + 0.5 * abs(x.length - y.length) }
        func choose(_ from: Int, _ picked: [Int]) {
            if picked.count == a.count {
                let c = zip(a, picked).reduce(Float(0)) { $0 + cost($1.0, b[$1.1]) }
                if c < bestCost { bestCost = c; best = picked }
                return
            }
            guard from < b.count, b.count - from >= a.count - picked.count else { return }
            choose(from + 1, picked + [from])
            choose(from + 1, picked)
        }
        choose(0, [])
        var out: [(from: RibbonRun, to: RibbonRun)] = zip(a, best).map { ($0, b[$1]) }
        for (j, r) in b.enumerated() where !best.contains(j) {
            let near = a.min { abs($0.mid - r.mid) < abs($1.mid - r.mid) }!
            out.append((.point(near.mid), r))
        }
        return out
    }

    enum Morph: Sendable { case spring, crossFade, cut }

    /// The strips for a change from `old` to `new` (nil `old`: the first frame, drawn at rest). Columns that don't
    /// change stay still; the rest start left to right as one wave.
    static func strips(from old: RibbonColumns?, to new: RibbonColumns, morph: Morph) -> (strips: [RibbonStrip], duration: Float) {
        let p = new.pitch
        var out: [RibbonStrip] = []
        out.reserveCapacity(new.stripCount + (old?.stripCount ?? 0))
        func still(_ c: Int, _ runs: [RibbonRun]) {
            for r in runs { out.append(RibbonStrip(x: (Float(c) + 0.5) * p, y0a: r.top, y1a: r.foot, y0b: r.top, y1b: r.foot, delay: 0, phase: 2, index: Float(c))) }
        }
        guard let old, old.pitch == p, morph != .cut else {
            for (c, r) in new.runs.sorted(by: { $0.key < $1.key }) { still(c, r) }
            return (out, 0)
        }
        let columns = Set(old.runs.keys).union(new.runs.keys).sorted()
        let changed = columns.filter { !same(old.runs[$0] ?? [], new.runs[$0] ?? []) }
        guard let firstChanged = changed.first, let lastChanged = changed.last else {
            for (c, r) in new.runs.sorted(by: { $0.key < $1.key }) { still(c, r) }
            return (out, 0)
        }
        let stagger = min(RibbonSpring.stagger, RibbonSpring.sweep / Float(max(1, lastChanged - firstChanged)))
        let changedSet = Set(changed)
        for c in columns {
            let a = old.runs[c] ?? [], b = new.runs[c] ?? []
            guard changedSet.contains(c) else { still(c, b); continue }
            let x = (Float(c) + 0.5) * p
            switch morph {
            case .crossFade:
                for r in a { out.append(RibbonStrip(x: x, y0a: r.top, y1a: r.foot, y0b: r.top, y1b: r.foot, delay: 0, phase: 0, index: Float(c))) }
                for r in b { out.append(RibbonStrip(x: x, y0a: r.top, y1a: r.foot, y0b: r.top, y1b: r.foot, delay: 0, phase: 1, index: Float(c))) }
            default:
                let delay = Float(c - firstChanged) * stagger
                for m in match(a, b) {
                    out.append(RibbonStrip(x: x, y0a: m.from.top, y1a: m.from.foot, y0b: m.to.top, y1b: m.to.foot, delay: delay, phase: 2, index: Float(c)))
                }
            }
        }
        let duration = morph == .crossFade ? RibbonSpring.crossFade
            : Float(lastChanged - firstChanged) * stagger + RibbonSpring.lag + RibbonSpring.settle
        return (out, duration)
    }

    static func same(_ a: [RibbonRun], _ b: [RibbonRun], tolerance: Float = 0.05) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0.top - $1.top) < tolerance && abs($0.foot - $1.foot) < tolerance }
    }

    /// Where every strip is at `t` into a change, as columns: the starting point when a change interrupts another.
    static func evaluate(_ strips: [RibbonStrip], at t: Float, pitch: Float, top: Float, foot: Float) -> RibbonColumns {
        var runs: [Int: [RibbonRun]] = [:]
        for s in strips {
            var r: RibbonRun
            switch s.phase {
            case 0: continue
            case 1: r = RibbonRun(top: s.y0b, foot: s.y1b)
            default:
                let p0 = RibbonSpring.progress(t - s.delay), p1 = RibbonSpring.progress(t - s.delay - RibbonSpring.lag)
                r = RibbonRun(top: s.y0a + (s.y0b - s.y0a) * p0, foot: s.y1a + (s.y1b - s.y1a) * p1)
            }
            if r.length > 0.01 { runs[Int(s.index), default: []].append(r) }
        }
        for k in runs.keys { runs[k] = tidy(runs[k]!.sorted { $0.top < $1.top }, minimum: 0.01) }
        return RibbonColumns(pitch: pitch, runs: runs, top: top, foot: foot)
    }
}
