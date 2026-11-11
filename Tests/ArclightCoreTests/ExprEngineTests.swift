import Foundation
import Testing

@testable import ArclightCore

/// Pins the expression helpers (prelude) and the engine's result conversion.
@Suite struct ExprEngineTests {
    let e = ExprEngine()

    func num(_ src: String, t: Double = 0, T: Double = 0, i: Int = 0, d: Double = 0, n: Int = 1) -> Double? {
        e.eval(src, t: t, T: T, i: i, d: d, n: n).double
    }

    @Test func mathHelpers() {
        #expect(num("clamp(5, 0, 1)") == 1 && num("clamp(-5, 0, 1)") == 0 && num("clamp(0.25, 0, 1)") == 0.25)
        #expect(num("lerp(10, 20, 0.25)") == 12.5)
        #expect(
            num("smoothstep(0, 1, 0.5)") == 0.5 && num("smoothstep(0, 1, -1)") == 0 && num("smoothstep(0, 1, 2)") == 1)
        #expect(num("ease('linear', 0.3)") == 0.3)
        #expect(num("ease('outCubic', 1)") == 1)
    }

    @Test func randomHelpersAreDeterministic() {
        let r = num("rand(3)")!
        #expect(r >= 0 && r < 1 && r == ExprEngine().eval("rand(3)", t: 0, T: 0).double)
        // noise passes through rand at integers and interpolates smoothly between them.
        #expect(num("noise(4)") == num("rand(4)"))
        let mid = num("noise(4.5)")!, a = num("rand(4)")!, b = num("rand(5)")!
        #expect(abs(mid - (a + b) / 2) < 1e-12)
        // wiggle(f, a) stays within ±a and depends on t.
        for t in stride(from: 0.0, to: 3, by: 0.37) {
            #expect(abs(num("wiggle(2, 10)", t: t)!) <= 10)
        }
        #expect(num("wiggle(2, 10)", t: 0.3) != num("wiggle(2, 10)", t: 1.3))
        #expect(num("wiggle(2, 10, 1)", t: 0.3) != num("wiggle(2, 10)", t: 0.3))
    }

    @Test func lampAndPick() {
        #expect(num("lamp(0.5, 1)") == 0)
        #expect(num("lamp(2, 1)") == 1)
        let flicker = num("lamp(1.05, 1)")!
        #expect(flicker > 0 && flicker < 1)
        // pick chooses exactly round(n * frac) instances, ranks 0..<k.
        let ranks = (0..<20).map { num("pick(i, n, 0.3, 7)", i: $0, n: 20)! }
        #expect(ranks.filter { $0 >= 0 }.sorted() == (0..<6).map(Double.init))
    }

    @Test func variablesAndMarkersAndStats() {
        #expect(num("t + T * 10 + i * 100 + d * 1000 + n * 10000", t: 1, T: 2, i: 3, d: 4, n: 5) == 54321)
        e.markerProvider = { $0 == "hit" ? 2.5 : nil }
        #expect(num("marker('hit')") == 2.5)
        #expect(e.eval("marker('none')", t: 0, T: 0) == .null)  // NaN is not a JSON value
        e.litProvider = { _ in (lit: 3, total: 12) }
        #expect(
            num("litFraction('crowd')") == 0.25 && num("litCount('crowd')") == 3 && num("instanceCount('crowd')") == 12)
    }

    @Test func resultConversion() {
        #expect(e.eval("'abc'", t: 0, T: 0) == .string("abc"))
        #expect(e.eval("t > 1", t: 2, T: 0) == .bool(true))
        #expect(e.eval("[1, 2]", t: 0, T: 0) == .array([1, 2]))
        #expect(e.eval("({a: 1})", t: 0, T: 0) == .object(["a": 1]))
        #expect(e.eval("1 / 0", t: 0, T: 0) == .null)
        #expect(e.eval("undefined", t: 0, T: 0) == .null)
        #expect(e.eval("throw 1", t: 0, T: 0) == .null)
    }

    @Test func returnBodiesAndTheReturnHeuristic() {
        #expect(num("var x = t * 2; return x + 1", t: 3) == 7)
        // The form is found by parsing, so the word "return" in a string or a property name is still an expression.
        #expect(num("'return'.length") == 6)
        #expect(num("({returnValue: 3}).returnValue") == 3)
        #expect(e.form("'return'.length") == .expression)
        #expect(e.form("x.returnValue") == .expression)
        #expect(e.form("return 1") == .body)
        #expect(e.form("if (t < 1) return 0; return t") == .body)
        // Sources that parse nowhere are bodies; a statement list without a return stays an (invalid) expression.
        #expect(e.form("var x = ; return x") == .body)
        #expect(e.form("1; 2") == .expression)
        #expect(e.compileError("1; 2") != nil)
    }

    /// Every expression in the examples, the UI fixture and the built-in templates is classified exactly as the
    /// old rule (`src.contains("return")` means a statement body) classified it, so it runs exactly as before.
    @Test func shippedExpressionsKeepTheirForm() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        var docs: [(String, JSONValue)] = []
        for dir in ["Examples", "Tests/Fixtures"] {
            let projects = try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "arclight" }
            for p in projects {
                let scenes = try FileManager.default.contentsOfDirectory(
                    at: p.appendingPathComponent("scenes"), includingPropertiesForKeys: nil
                ).filter { $0.pathExtension == "json" }
                for s in scenes {
                    let v = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: s))
                    docs.append(("\(p.lastPathComponent)/\(s.lastPathComponent)", v))
                }
            }
        }
        #expect(BuiltInTemplates.all.count == BuiltInTemplates.sources.count)
        for t in BuiltInTemplates.all {
            let scene = try Templates.instantiate(t, params: [:], sceneId: "s", canvas: (1920, 1080))
            let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(scene))
            docs.append(("template \(t.id)", json))
        }
        func exprs(_ v: JSONValue, into out: inout [String]) {
            switch v {
            case .object(let o):
                if o.count == 1, let s = o["expr"]?.string { out.append(s); return }
                o.values.forEach { exprs($0, into: &out) }
            case .array(let a): a.forEach { exprs($0, into: &out) }
            default: break
            }
        }
        var total = 0, bodies = 0
        for (name, doc) in docs {
            var found: [String] = []
            exprs(doc, into: &found)
            for src in found {
                let old: ExprEngine.Form = src.contains("return") ? .body : .expression
                #expect(e.form(src) == old, "\(name): \(src)")
                #expect(e.compileError(src) == nil, "\(name): \(src)")
                total += 1
                if old == .body { bodies += 1 }
            }
        }
        // Guards against the walk silently finding nothing.
        #expect(total >= 30 && bodies >= 5, "found \(total) expressions, \(bodies) bodies")
    }

    @Test func compileErrors() {
        #expect(e.compileError("t * 2") == nil)
        #expect(e.compileError("t +* 2") != nil)
        #expect(e.compileError("nope(t)") != nil)  // throws at t = 0
    }

    @Test func batchEvaluation() {
        #expect(e.evalBatch("i * 2 + t", t: 1, T: 0, d: 5, n: 4) == [1, 3, 5, 7])
        #expect(e.evalBatch("var k = i; return k * 10", t: 0, T: 0, d: 0, n: 3) == [0, 10, 20])
        #expect(e.evalBatch("'x'", t: 0, T: 0, d: 0, n: 2).map { $0.allSatisfy(\.isNaN) } == true)
        #expect(e.evalBatch("i +* 1", t: 0, T: 0, d: 0, n: 2) == nil)
        // Batch and single evaluation agree.
        let batch = e.evalBatch("wiggle(3, 5, i)", t: 0.7, T: 0, d: 0, n: 3)!
        for i in 0..<3 { #expect(batch[i] == num("wiggle(3, 5, i)", t: 0.7, i: i)) }
    }
}
