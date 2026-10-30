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
        #expect(MemoryLayout<RibbonStrip>.stride == 32)
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
        #expect(duration >= RibbonSpring.settle && duration < 2)
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
        let w = Double(RibbonSpring.omega), z = Double(RibbonSpring.damping)
        var x = 1.0, v = 0.0, t = 0.0
        let dt = 1e-5
        for check in stride(from: 0.05, through: 1.0, by: 0.05) {
            while t < check { let a = -w * w * x - 2 * z * w * v; v += a * dt; x += v * dt; t += dt }
            #expect(abs(Double(RibbonSpring.progress(Float(t))) - (1 - x)) < 2e-3)
        }
        #expect(RibbonSpring.progress(0) == 0)
        #expect(abs(RibbonSpring.progress(RibbonSpring.settle) - 1) < 0.003)
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
