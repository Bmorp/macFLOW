import CoreGraphics
import Foundation

/// One stretch of a column that the glyphs cover, top to foot, in points (y down). `top` and `foot` are where the
/// outline crosses the middle of the column; the cut at each end is a straight line through that point, rising
/// `topTilt` / `footTilt` points from the column's left edge to its right, so a diagonal stroke ends in a diagonal
/// and not a staircase. `left` and `right` (0…1 across the column) are where the glyph starts and stops inside it,
/// for the columns that straddle a glyph's side.
struct RibbonRun: Equatable, Sendable {
    var top: Float
    var foot: Float
    var topTilt: Float = 0
    var footTilt: Float = 0
    var left: Float = 0
    var right: Float = 1
    /// Across the stretch the glyph covers (not the column's centre, which a run that stops short of it only
    /// reaches by extrapolating its ends).
    var centre: Float { 0.5 * (left + right) }
    var mid: Float { 0.5 * (topAt(centre) + footAt(centre)) }
    var length: Float { footAt(centre) - topAt(centre) }
    func topAt(_ u: Float) -> Float { top + topTilt * (u - 0.5) }
    func footAt(_ u: Float) -> Float { foot + footTilt * (u - 0.5) }
    /// A run of no length at `y`: where a new run grows from, or an old one collapses into.
    static func point(_ y: Float) -> RibbonRun { RibbonRun(top: y, foot: y) }
    /// Whether the run still covers anything (at either side of what it covers).
    var isVisible: Bool { max(footAt(left) - topAt(left), footAt(right) - topAt(right)) >= 0.01 }

    /// The run between the outline's crossings on two sides of a column (`x` across it, 0…1).
    init(top: Float, foot: Float, topTilt: Float = 0, footTilt: Float = 0, left: Float = 0, right: Float = 1) {
        self.top = top; self.foot = foot; self.topTilt = topTilt; self.footTilt = footTilt; self.left = left; self.right = right
    }

    /// From the ends at `x0` and `x1` (0…1 across the column): extended along each end's line to the column's centre.
    init(left a: (top: Float, foot: Float), at x0: Float, right b: (top: Float, foot: Float), at x1: Float) {
        let span = x1 - x0
        if span < 0.02 {
            // Too narrow to have a slope: a sliver, which `tidy` drops.
            self.init(top: 0.5 * (a.top + b.top), foot: 0.5 * (a.foot + b.foot), left: x0, right: x1)
            return
        }
        let tt = (b.top - a.top) / span, ft = (b.foot - a.foot) / span
        self.init(top: a.top + tt * (0.5 - x0), foot: a.foot + ft * (0.5 - x0), topTilt: tt, footTilt: ft, left: x0, right: x1)
    }
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
    /// The slope of each end across the column (see `RibbonRun.topTilt`), old and new.
    var t0a: Float = 0, t1a: Float = 0
    var t0b: Float = 0, t1b: Float = 0
    /// Where the glyph starts and stops across the column, old and new.
    var la: Float = 0, ra: Float = 1
    var lb: Float = 0, rb: Float = 1
    var delay: Float
    /// 0: the old run, fading out; 1: the new run, fading in (Reduce Motion); 2: a spring from a to b.
    var phase: Float
    var index: Float

    init(x: Float, from a: RibbonRun, to b: RibbonRun, delay: Float, phase: Float, index: Float) {
        self.x = x
        y0a = a.top; y1a = a.foot; y0b = b.top; y1b = b.foot
        t0a = a.topTilt; t1a = a.footTilt; t0b = b.topTilt; t1b = b.footTilt
        la = a.left; ra = a.right; lb = b.left; rb = b.right
        self.delay = delay; self.phase = phase; self.index = index
    }
}

/// The spring every run end rides: underdamped a touch, so strips settle like ribbon, not like a counter. Ribbon.metal
/// evaluates the same closed form.
enum RibbonSpring {
    /// The foot of each run follows its top by this much, so a strip rolls rather than slides.
    static let lag: Float = 0.035
    /// Columns start one after another, left to right, `stagger` apart, but a whole change sweeps in at most the
    /// pace's `sweep`.
    static let stagger: Float = 0.008
    static let crossFade: Float = 0.2

    static func progress(_ t: Float, omega: Float = RibbonPace.clock.omega, zeta: Float = RibbonPace.clock.damping) -> Float {
        guard t > 0 else { return 0 }
        // Within sub-pixel of rest it is at rest, exactly: a run that collapsed into a point is then no run at all.
        if t >= settle(omega: omega, zeta: zeta) { return 1 }
        let x: Float
        if zeta < 1 {
            let wd = omega * (1 - zeta * zeta).squareRoot()
            x = exp(-zeta * omega * t) * (cos(wd * t) + (zeta * omega / wd) * sin(wd * t))
        } else {
            x = (1 + omega * t) * exp(-omega * t)
        }
        return 1 - x
    }

    /// When the spring is within 0.2 % of rest.
    static func settle(omega: Float, zeta: Float) -> Float {
        let z = min(zeta, 0.999)
        return -log(0.002 * (1 - z * z).squareRoot()) / (z * omega)
    }
}

/// How quickly figures flow into the next ones.
struct RibbonPace: Equatable, Sendable {
    var response: Float
    var damping: Float
    var sweep: Float

    /// The clock, once a minute: unhurried, a whisper of overshoot.
    static let clock = RibbonPace(response: 0.5, damping: 0.8, sweep: 0.45)
    /// A count that ticks every second: done well inside the second.
    static let count = RibbonPace(response: 0.3, damping: 0.86, sweep: 0.12)

    var omega: Float { 2 * .pi / response }

    func progress(_ t: Float) -> Float { RibbonSpring.progress(t, omega: omega, zeta: damping) }

    /// When the spring is within 0.2 % of rest (sub-pixel on any run).
    var settle: Float { RibbonSpring.settle(omega: omega, zeta: damping) }
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
            return max(2, min(96, Int(len / 2)))
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
        tidy(crossings(edges, x: x))
    }

    /// The same, untidied: every stretch, however short.
    static func crossings(_ edges: [Edge], x: Float) -> [RibbonRun] {
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
        return out
    }

    /// Drops slivers, closes hairline gaps, and keeps at most four runs (closing the smallest gaps first). Runs are
    /// taken in order down the column; two that cover different stretches across it never merge.
    static func tidy(_ input: [RibbonRun], minimum: Float = 0.5) -> [RibbonRun] {
        var runs: [RibbonRun] = []
        for r in input where r.length >= minimum && r.right - r.left >= 0.02 {
            if let last = runs.last, gap(last, r) < minimum { runs[runs.count - 1] = join(last, r) } else { runs.append(r) }
        }
        while runs.count > maxRuns {
            var best = 0
            for i in 0..<(runs.count - 1) where gap(runs[i], runs[i + 1]) < gap(runs[best], runs[best + 1]) { best = i }
            runs[best] = join(runs[best], runs[best + 1])
            runs.remove(at: best + 1)
        }
        return runs
    }

    /// The room between a run and the one below it, where both are there (infinite when they sit side by side).
    static func gap(_ a: RibbonRun, _ b: RibbonRun) -> Float {
        let lo = max(a.left, b.left), hi = min(a.right, b.right)
        guard lo < hi else { return .infinity }
        return min(b.topAt(lo) - a.footAt(lo), b.topAt(hi) - a.footAt(hi))
    }

    /// One run from two that sit one above the other: the first's top, the second's foot.
    static func join(_ a: RibbonRun, _ b: RibbonRun) -> RibbonRun {
        var r = a
        r.foot = max(a.foot, b.foot)
        r.footTilt = b.footTilt
        r.left = min(a.left, b.left)
        r.right = max(a.right, b.right)
        return r
    }

    /// The outline cut into columns: in each, the runs between where the outline crosses the column's two edges.
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
            let r = column(buckets[c - first], left: Float(c) * p, pitch: p)
            if !r.isEmpty { out[c] = r }
        }
        return RibbonColumns(pitch: p, runs: out, top: Float(box.minY), foot: Float(box.maxY))
    }

    /// The runs of one column: where the outline crosses its left and right edges, run by run, so each strip ends in
    /// the outline's own slope. A run that starts or stops inside the column (a glyph's side) is followed to where it
    /// does. Neighbouring columns share an edge, so their ends meet exactly.
    static func column(_ edges: [Edge], left xl: Float, pitch p: Float) -> [RibbonRun] {
        let xr = xl + p
        let a = crossings(edges, x: xl).filter { $0.length > 0 }, b = crossings(edges, x: xr).filter { $0.length > 0 }
        func overlap(_ x: RibbonRun, _ y: RibbonRun) -> Float { min(x.foot, y.foot) - max(x.top, y.top) }
        var out: [RibbonRun] = []
        var taken = Set<Int>()
        for ra in a {
            let best = b.indices.filter { !taken.contains($0) && overlap(ra, b[$0]) > 0 }.max { overlap(ra, b[$0]) < overlap(ra, b[$1]) }
            if let j = best {
                taken.insert(j)
                out.append(RibbonRun(left: (ra.top, ra.foot), at: 0, right: (b[j].top, b[j].foot), at: 1))
            } else if let end = follow(edges, from: ra, at: xl, toward: xr) {
                out.append(RibbonRun(left: (ra.top, ra.foot), at: 0, right: (end.run.top, end.run.foot), at: (end.x - xl) / p))
            }
        }
        for (j, rb) in b.enumerated() where !taken.contains(j) {
            if let start = follow(edges, from: rb, at: xr, toward: xl) {
                out.append(RibbonRun(left: (start.run.top, start.run.foot), at: (start.x - xl) / p, right: (rb.top, rb.foot), at: 1))
            }
        }
        return tidy(out.sorted { $0.mid < $1.mid })
    }

    /// Walks a run that stops short of the other side of the column to where it ends (bisection: the outline is
    /// known at both ends, so a dozen steps pin it well under a thousandth of a point).
    static func follow(_ edges: [Edge], from run: RibbonRun, at x0: Float, toward x1: Float) -> (x: Float, run: RibbonRun)? {
        var near = x0, far = x1, cur = run
        func carrier(_ x: Float, _ r: RibbonRun) -> RibbonRun? {
            crossings(edges, x: x).filter { $0.length > 0 && min($0.foot, r.foot) - max($0.top, r.top) > 0 }
                .max { min($0.foot, r.foot) - max($0.top, r.top) < min($1.foot, r.foot) - max($1.top, r.top) }
        }
        for _ in 0..<14 {
            let mid = 0.5 * (near + far)
            if let r = carrier(mid, cur) { near = mid; cur = r } else { far = mid }
        }
        guard abs(near - x0) > 1e-3 else { return nil }
        return (near, cur)
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
    static func strips(from old: RibbonColumns?, to new: RibbonColumns, morph: Morph, pace: RibbonPace = .clock) -> (strips: [RibbonStrip], duration: Float) {
        let p = new.pitch
        var out: [RibbonStrip] = []
        out.reserveCapacity(new.stripCount + (old?.stripCount ?? 0))
        func still(_ c: Int, _ runs: [RibbonRun]) {
            for r in runs { out.append(RibbonStrip(x: (Float(c) + 0.5) * p, from: r, to: r, delay: 0, phase: 2, index: Float(c))) }
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
        let stagger = min(RibbonSpring.stagger, pace.sweep / Float(max(1, lastChanged - firstChanged)))
        let changedSet = Set(changed)
        for c in columns {
            let a = old.runs[c] ?? [], b = new.runs[c] ?? []
            guard changedSet.contains(c) else { still(c, b); continue }
            let x = (Float(c) + 0.5) * p
            switch morph {
            case .crossFade:
                for r in a { out.append(RibbonStrip(x: x, from: r, to: r, delay: 0, phase: 0, index: Float(c))) }
                for r in b { out.append(RibbonStrip(x: x, from: r, to: r, delay: 0, phase: 1, index: Float(c))) }
            default:
                let delay = Float(c - firstChanged) * stagger
                for m in match(a, b) {
                    out.append(RibbonStrip(x: x, from: m.from, to: m.to, delay: delay, phase: 2, index: Float(c)))
                }
            }
        }
        let duration = morph == .crossFade ? RibbonSpring.crossFade
            : Float(lastChanged - firstChanged) * stagger + RibbonSpring.lag + pace.settle
        return (out, duration)
    }

    static func same(_ a: [RibbonRun], _ b: [RibbonRun], tolerance: Float = 0.05) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy {
            abs($0.top - $1.top) < tolerance && abs($0.foot - $1.foot) < tolerance
                && abs($0.topTilt - $1.topTilt) < tolerance && abs($0.footTilt - $1.footTilt) < tolerance
                && abs($0.left - $1.left) < 0.01 && abs($0.right - $1.right) < 0.01
        }
    }

    /// Where every strip is at `t` into a change, as columns: the starting point when a change interrupts another.
    static func evaluate(_ strips: [RibbonStrip], at t: Float, pitch: Float, top: Float, foot: Float, pace: RibbonPace = .clock) -> RibbonColumns {
        var runs: [Int: [RibbonRun]] = [:]
        for s in strips {
            var r: RibbonRun
            switch s.phase {
            case 0: continue
            case 1: r = RibbonRun(top: s.y0b, foot: s.y1b, topTilt: s.t0b, footTilt: s.t1b, left: s.lb, right: s.rb)
            default:
                let p0 = pace.progress(t - s.delay), p1 = pace.progress(t - s.delay - RibbonSpring.lag)
                r = RibbonRun(top: s.y0a + (s.y0b - s.y0a) * p0, foot: s.y1a + (s.y1b - s.y1a) * p1,
                              topTilt: s.t0a + (s.t0b - s.t0a) * p0, footTilt: s.t1a + (s.t1b - s.t1a) * p1,
                              left: s.la + (s.lb - s.la) * p0, right: s.ra + (s.rb - s.ra) * p0)
            }
            if r.isVisible { runs[Int(s.index), default: []].append(r) }
        }
        for k in runs.keys { runs[k] = tidy(runs[k]!.sorted { $0.mid < $1.mid }, minimum: 0.01) }
        return RibbonColumns(pitch: pitch, runs: runs, top: top, foot: foot)
    }
}
