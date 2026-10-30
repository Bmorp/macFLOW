import Testing
import Foundation
import CoreGraphics
import Metal
@testable import Atoll

@Suite("Prism: fallbacks")
struct PrismFallbackTests {
    @Test func tiersFollowTheMachine() {
        var env = PrismEnvironment(libraryLoaded: true)
        #expect(env.tier == .full)
        env.lowPower = true
        #expect(env.tier == .saver)
        env.thermal = .serious
        #expect(env.tier == .still)
        env.thermal = .critical
        #expect(env.tier == .flat)
        var intel = PrismEnvironment(libraryLoaded: true)
        intel.unifiedMemory = false
        #expect(intel.tier == .still)
        #expect(intel.maxFrameRate == 60)
        #expect(PrismEnvironment(libraryLoaded: false).tier == .off)
    }

    @Test func whatEachTierDraws() {
        let full = PrismEnvironment(libraryLoaded: true)
        #expect(full.samplesBehind && full.dispersion && full.movingSparks && full.morphs && !full.crossFades)
        #expect(full.maxFrameRate == 120)

        var saver = full
        saver.lowPower = true
        #expect(!saver.dispersion && !saver.movingSparks && saver.morphs && saver.maxFrameRate == 60)

        var rt = full
        rt.reduceTransparency = true
        #expect(!rt.samplesBehind && !rt.dispersion && rt.morphs)

        var rm = full
        rm.reduceMotion = true
        #expect(!rm.morphs && rm.crossFades)

        var hot = full
        hot.thermal = .serious
        #expect(!hot.morphs && !hot.crossFades && !hot.movingSparks)
    }

    @Test func aMissingOrBrokenLibraryIsIgnored() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        #expect(PrismLibrary.load(URL(fileURLWithPath: "/nonexistent/Prism.metallib"), device: device) == nil)
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("prism-junk-\(UUID().uuidString).metallib")
        try Data("not a library".utf8).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        #expect(PrismLibrary.load(junk, device: device) == nil)
    }

    @Test func looksInTheBundleFirst() {
        let list = PrismLibrary.candidates(environment: ["ATOLL_METALLIB": "/tmp/x.metallib"])
        #expect(list.first?.lastPathComponent == PrismLibrary.fileName)
        #expect(list.contains(URL(fileURLWithPath: "/tmp/x.metallib")))
        #expect(list.firstIndex(of: URL(fileURLWithPath: "/tmp/x.metallib"))! >= 1)
    }

    @Test func shadersCompileAndExportTheirFunctions() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let lib = try PrismLibrary.compileSources(device: device)
        #expect(PrismLibrary.validate(lib, effects: false))
        for name in PrismLibrary.effectFunctions { #expect(lib.makeFunction(name: name) != nil) }
    }

    @Test func uniformsMatchTheShader() {
        // Ribbon.metal's RibbonUniforms: 20 four-byte fields, then two float4s on 16-byte boundaries.
        #expect(MemoryLayout<RibbonUniforms>.offset(of: \.flags) == 72)
        #expect(MemoryLayout<RibbonUniforms>.offset(of: \.tint) == 80)
        #expect(MemoryLayout<RibbonUniforms>.offset(of: \.backdrop) == 96)
        #expect(MemoryLayout<RibbonUniforms>.stride == 112)
        #expect(MemoryLayout<RibbonStrip>.stride == 64)
    }
}

@Suite("Prism: ribbon numerals")
struct RibbonTests {
    @Test func aColumnThroughABarIsOneRun() {
        let path = CGPath(rect: CGRect(x: 0, y: 10, width: 40, height: 30), transform: nil)
        let runs = RibbonLayout.runs(RibbonLayout.edges(path), x: 12)
        #expect(runs.count == 1)
        #expect(abs(runs[0].top - 10) < 0.01 && abs(runs[0].foot - 40) < 0.01)
    }

    @Test func holesSplitAColumn() {
        // An "O": an ellipse with a hole (even-odd as two subpaths of opposite direction, as glyphs are drawn).
        let p = CGMutablePath()
        p.addEllipse(in: CGRect(x: 0, y: 0, width: 100, height: 140))
        var flip = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 100, ty: 0)
        p.addPath(CGPath(ellipseIn: CGRect(x: 25, y: 25, width: 50, height: 90), transform: &flip))
        let runs = RibbonLayout.runs(RibbonLayout.edges(p), x: 50)
        #expect(runs.count == 2)
        #expect(abs(runs[0].top) < 0.5 && abs(runs[1].foot - 140) < 0.5)
    }

    @Test func tidyKeepsFourRunsAndDropsSlivers() {
        let many = (0..<7).map { RibbonRun(top: Float($0) * 10, foot: Float($0) * 10 + 5 + Float($0)) }
        let t = RibbonLayout.tidy(many)
        #expect(t.count == RibbonLayout.maxRuns)
        #expect(t.first?.top == 0 && t.last?.foot == many.last?.foot)
        #expect(RibbonLayout.tidy([RibbonRun(top: 0, foot: 0.2), RibbonRun(top: 5, foot: 9)]).count == 1)
    }

    @Test func runsAreMatchedInOrderAndExtrasGrowFromTheNearest() {
        let a = [RibbonRun(top: 0, foot: 10)]
        let b = [RibbonRun(top: 0, foot: 9), RibbonRun(top: 40, foot: 60)]
        let m = RibbonLayout.match(a, b)
        #expect(m.count == 2)
        #expect(m[0].from == a[0] && m[0].to == b[0])
        #expect(m[1].from == .point(5) && m[1].to == b[1])
        // Into an empty column: roll up into the top; out of one: unroll from the top.
        #expect(RibbonLayout.match(a, []).first?.to == .point(0))
        #expect(RibbonLayout.match([], b).last?.from == .point(40))
        // Fewer after than before: the reverse.
        let back = RibbonLayout.match(b, a)
        #expect(back.count == 2 && back.contains { $0.from == b[1] && $0.to == .point(5) })
    }

    @Test func onlyChangedColumnsMoveAndTheyMoveLeftToRight() {
        let old = RibbonColumns(pitch: 5, runs: [0: [RibbonRun(top: 0, foot: 10)], 1: [RibbonRun(top: 0, foot: 10)], 4: [RibbonRun(top: 0, foot: 10)]], top: 0, foot: 10)
        var new = old
        new.runs[1] = [RibbonRun(top: 2, foot: 8)]
        new.runs[4] = [RibbonRun(top: 0, foot: 4), RibbonRun(top: 6, foot: 10)]
        let (strips, duration) = RibbonLayout.strips(from: old, to: new, morph: .spring)
        #expect(strips.filter { $0.index == 0 }.allSatisfy { $0.delay == 0 && $0.y0a == $0.y0b && $0.y1a == $0.y1b })
        let d1 = strips.first { $0.index == 1 }!.delay, d4 = strips.first { $0.index == 4 }!.delay
        #expect(d1 == 0 && d4 > d1)
        #expect(duration >= RibbonPace.clock.settle && duration < 2)
        // A count that ticks every second settles inside the second, even when every column changes.
        let wide = RibbonColumns(pitch: 2, runs: Dictionary(uniqueKeysWithValues: (0..<60).map { ($0, [RibbonRun(top: 0, foot: 10)]) }), top: 0, foot: 10)
        var moved = wide
        for k in moved.runs.keys { moved.runs[k] = [RibbonRun(top: 4, foot: 10)] }
        #expect(RibbonLayout.strips(from: wide, to: moved, morph: .spring, pace: .count).duration < 0.9)
        // Settled, the strips are exactly the new columns.
        #expect(RibbonLayout.evaluate(strips, at: duration + 0.01, pitch: 5, top: 0, foot: 10).runs.mapValues { $0.count } == new.runs.mapValues { $0.count })
    }

    @Test func reduceMotionCrossFadesAndAColdStartDoesNotMove() {
        let old = RibbonColumns(pitch: 5, runs: [0: [RibbonRun(top: 0, foot: 10)]], top: 0, foot: 10)
        let new = RibbonColumns(pitch: 5, runs: [0: [RibbonRun(top: 3, foot: 10)]], top: 0, foot: 10)
        let fade = RibbonLayout.strips(from: old, to: new, morph: .crossFade)
        #expect(fade.duration == RibbonSpring.crossFade)
        #expect(Set(fade.strips.map(\.phase)) == [0, 1])
        let cold = RibbonLayout.strips(from: nil, to: new, morph: .spring)
        #expect(cold.duration == 0 && cold.strips.allSatisfy { $0.phase == 2 && $0.y0a == $0.y0b })
        #expect(RibbonLayout.strips(from: old, to: new, morph: .cut).duration == 0)
    }

    @Test func theClosedFormSpringMatchesTheSpring() {
        // Integrate x'' = −ω²x − 2ζωx' from x = 1 at rest and compare with the shader's closed form.
        let w = Double(RibbonPace.clock.omega), z = Double(RibbonPace.clock.damping)
        var x = 1.0, v = 0.0, t = 0.0
        let dt = 1e-5
        for check in stride(from: 0.05, through: 1.0, by: 0.05) {
            while t < check { let a = -w * w * x - 2 * z * w * v; v += a * dt; x += v * dt; t += dt }
            #expect(abs(Double(RibbonSpring.progress(Float(t))) - (1 - x)) < 2e-3)
        }
        #expect(RibbonSpring.progress(0) == 0)
        #expect(abs(RibbonPace.clock.progress(RibbonPace.clock.settle) - 1) < 0.003)
        #expect(abs(RibbonPace.count.progress(RibbonPace.count.settle) - 1) < 0.003)
    }

    @Test func theTimeBecomesAboutAThousandStrips() {
        let size = CGSize(width: 1728, height: 1117)
        let path = TimeGlyphs.path(hour: "10", minute: "08", size: size.height * ClockLayout.timeSize, in: CGRect(origin: .zero, size: size))
        let cols = RibbonLayout.columns(path, pitch: 5)
        #expect(cols.runs.values.allSatisfy { $0.count <= RibbonLayout.maxRuns && $0.allSatisfy { $0.length > 0 } })
        #expect((250...1200).contains(cols.stripCount))
        // The 8's middle column crosses three strokes.
        #expect(cols.runs.values.contains { $0.count == 3 })
        #expect(cols.top < cols.foot)
    }

    // MARK: Edges and rest

    @Test func diagonalsEndInTheirOwnSlope() {
        // A band rising at 45°: every strip's ends are cut along it, a pitch (5 pt) higher at the right edge than the left,
        // and neighbouring strips meet exactly, so the silhouette is the outline and not a staircase.
        let band = CGMutablePath()
        band.move(to: CGPoint(x: 0, y: 100)); band.addLine(to: CGPoint(x: 100, y: 0))
        band.addLine(to: CGPoint(x: 100, y: 40)); band.addLine(to: CGPoint(x: 0, y: 140)); band.closeSubpath()
        let cols = RibbonLayout.columns(band, pitch: 5)
        let a = try! #require(cols.runs[4]?.first), b = try! #require(cols.runs[5]?.first)
        #expect(abs(a.topTilt + 5) < 0.01 && abs(a.footTilt + 5) < 0.01)
        #expect(abs(a.top - 77.5) < 0.01 && abs(a.length - 40) < 0.01)
        #expect(abs(a.topAt(1) - b.topAt(0)) < 0.01 && abs(a.footAt(1) - b.footAt(0)) < 0.01)
    }

    @Test func aColumnThatStartsInsideIsFollowedToWhereItStarts() {
        let bar = CGPath(rect: CGRect(x: 12.5, y: 10, width: 25, height: 20), transform: nil)
        let cols = RibbonLayout.columns(bar, pitch: 5)
        let edge = try! #require(cols.runs[2]?.first)
        #expect(abs(edge.left - 0.5) < 0.01 && edge.right == 1)
        #expect(cols.runs[1] == nil && cols.runs[3]?.first?.left == 0)
        // And one that stops inside it.
        let end = try! #require(RibbonLayout.columns(bar, pitch: 5).runs[7]?.first)
        #expect(abs(end.right - 0.5) < 0.01)
    }

    /// The figures StandBy draws, at its size: every units digit after "12:3".
    private static func clockColumns(_ units: Int) -> RibbonColumns {
        let size = CGSize(width: 1470, height: 956)
        let path = TimeGlyphs.path(hour: "12", minute: "3\(units)", size: size.height * ClockLayout.timeSize, in: CGRect(origin: .zero, size: size))
        return RibbonLayout.columns(path, pitch: 5)
    }

    /// No two runs of a column overlap anywhere across it: one clean digit, not two layered ones.
    private static func overlaps(_ c: RibbonColumns) -> [Int] {
        c.runs.filter { _, runs in
            zip(runs, runs.dropFirst()).contains { a, b in
                let lo = max(a.left, b.left), hi = min(a.right, b.right)
                guard lo < hi else { return false }
                return [lo, 0.5 * (lo + hi), hi].contains { b.topAt($0) < a.footAt($0) - 0.01 }
            }
        }.map(\.key).sorted()
    }

    @Test func atRestEveryColumnIsOneCleanDigit() {
        for d in 0...9 {
            let cols = Self.clockColumns(d)
            #expect(Self.overlaps(cols).isEmpty, "units \(d)")
            // The strips handed to the GPU for a cold start are exactly those runs, once each.
            let strips = RibbonLayout.strips(from: nil, to: cols, morph: .spring).strips
            #expect(strips.count == cols.stripCount)
            #expect(strips.allSatisfy { $0.y0a == $0.y0b && $0.y1a == $0.y1b && $0.t0a == $0.t0b && $0.t1a == $0.t1b && $0.delay == 0 })
        }
    }

    @Test func aSettledChangeIsExactlyTheNewFigureWithNothingOfTheOld() {
        let all = (0...9).map(Self.clockColumns)
        for (from, old) in all.enumerated() {
            for (to, new) in all.enumerated() where from != to {
                for pace in [RibbonPace.clock, RibbonPace.count] {
                    let (strips, duration) = RibbonLayout.strips(from: old, to: new, morph: .spring, pace: pace)
                    let settled = RibbonLayout.evaluate(strips, at: duration + 0.001, pitch: new.pitch, top: new.top, foot: new.foot, pace: pace)
                    #expect(Set(settled.runs.keys) == Set(new.runs.keys), "\(from)→\(to)")
                    for (c, want) in new.runs {
                        let got = settled.runs[c] ?? []
                        #expect(got.count == want.count && RibbonLayout.same(got, want, tolerance: 0.01), "\(from)→\(to) column \(c)")
                    }
                }
            }
        }
    }

    @Test func aRunThatCollapsedLeavesNothingBehind() {
        // A pair of runs that becomes one: at rest the extra one is no run at all (not a sliver the GPU would still shade).
        let old = RibbonColumns(pitch: 5, runs: [0: [RibbonRun(top: 0, foot: 30), RibbonRun(top: 50, foot: 80)]], top: 0, foot: 80)
        let new = RibbonColumns(pitch: 5, runs: [0: [RibbonRun(top: 0, foot: 80)]], top: 0, foot: 80)
        let (strips, duration) = RibbonLayout.strips(from: old, to: new, morph: .spring)
        #expect(strips.count == 2)
        let at = RibbonPace.clock.settle + 0.2
        #expect(duration <= at)
        let runs = RibbonLayout.evaluate(strips, at: duration, pitch: 5, top: 0, foot: 80).runs[0] ?? []
        #expect(runs.count == 1 && abs(runs[0].length - 80) < 0.01)
    }

    @Test @MainActor func aSettledChangeDrawsLikeAColdStart() throws {
        guard let r = PrismRenderer.shared else { return }   // no GPU here
        let size = CGSize(width: 520, height: 220)
        func scene(_ minutes: String) -> RibbonScene {
            RibbonScene(lead: "12", trail: minutes, fontSize: 110, canvas: size, layout: CGRect(origin: .zero, size: size),
                        style: .standBy, env: PrismEnvironment(libraryLoaded: true))
        }
        let a = scene("55"), b = scene("56")
        let old = RibbonLayout.columns(a.outline, pitch: 5), new = RibbonLayout.columns(b.outline, pitch: 5)
        let (strips, duration) = RibbonLayout.strips(from: old, to: new, morph: .spring)
        let u = b.uniforms(columns: new, time: duration, duration: duration, scale: 2, hasBackdrop: false)
        let moved = try #require(r.frame(width: 1040, height: 440, uniforms: u, strips: strips, backdrop: nil))
        let cold = try #require(r.still(b, scale: 2))
        let x = try #require(moved.dataProvider?.data as Data?), y = try #require(cold.dataProvider?.data as Data?)
        #expect(x.count == y.count)
        let off = zip(x, y).filter { abs(Int($0) - Int($1)) > 3 }.count
        #expect(off == 0, "\(off) channel values differ between the settled change and a cold start")
    }

    @Test @MainActor func aStillFrameDraws() throws {
        guard let r = PrismRenderer.shared else { return }   // no GPU here
        let size = CGSize(width: 300, height: 120)
        let scene = RibbonScene(lead: "9", trail: "41", fontSize: 80, canvas: size, layout: CGRect(origin: .zero, size: size),
                                style: .standBy, env: PrismEnvironment(libraryLoaded: true))
        let image = try #require(r.still(scene, scale: 2))
        #expect(image.width == 600 && image.height == 240)
        let data = try #require(image.dataProvider?.data as Data?)
        let lit = stride(from: 3, to: data.count, by: 4).filter { data[$0] > 0 }.count
        #expect(lit > 2000)
    }
}
