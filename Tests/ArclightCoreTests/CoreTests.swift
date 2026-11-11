import CoreGraphics
import CryptoKit
import Foundation
import Testing
import simd

@testable import ArclightCore

@Suite struct ModelTests {
    @Test func nodeRoundTrip() throws {
        let json =
            #"{"id":"a","type":"text","in":0.5,"text":"Hi","x":{"k":[[0,0],[1,100,"outExpo"]]},"y":{"expr":"t*2"}}"#
        let n = try JSONDecoder().decode(Node.self, from: Data(json.utf8))
        #expect(n.start == 0.5)
        #expect(n.props["text"] == .value("Hi"))
        guard case .keys(let ks)? = n.props["x"] else { Issue.record("x not keyframes"); return }
        #expect(ks.count == 2 && ks[1].ease == .named("outExpo"))
        #expect(n.props["y"] == .expr("t*2"))
        let back = try JSONDecoder().decode(Node.self, from: JSONEncoder().encode(n))
        #expect(back == n)
    }

    @Test func validationCatchesProblems() {
        var s = Scene(id: "s")
        s.nodes = [
            Node(id: "a", type: "text"), Node(id: "a", type: "blob"), Node(id: "c", type: "group", parent: "zzz"),
        ]
        let msgs = Validator.validate(s).map(\.message).joined(separator: "|")
        #expect(msgs.contains("needs 'text'"))
        #expect(msgs.contains("duplicate id"))
        #expect(msgs.contains("unknown type"))
        #expect(msgs.contains("does not exist"))
    }

    @Test func validationCatchesBadExpression() {
        var s = Scene(id: "s")
        s.nodes = [Node(id: "a", type: "group", props: ["x": .expr("t +* 2")])]
        #expect(!Validator.validate(s, expr: ExprEngine()).isEmpty)
    }
}

@Suite struct AnimationTests {
    @Test func easingEndpoints() {
        for name in Easing.names where name != "hold" {
            let e = Easing(name)
            #expect(abs(e.apply(0)) < 1e-6, "\(name)(0)")
            #expect(abs(e.apply(1) - 1) < 1e-6, "\(name)(1)")
        }
        #expect(abs(Easing.bezier(0.25, 0.1, 0.25, 1).apply(1) - 1) < 1e-6)
    }

    @Test func keyframeInterpolation() {
        let ev = Evaluator()
        let p = Prop.keys([Keyframe(t: 0, v: 0), Keyframe(t: 2, v: 100)])
        #expect(ev.value(p, t: 1, T: 1) == .number(50))
        #expect(ev.value(p, t: -1, T: 0) == .number(0))
        #expect(ev.value(p, t: 5, T: 5) == .number(100))
        let hold = Prop.keys([Keyframe(t: 0, v: "a"), Keyframe(t: 1, v: "b")])
        #expect(ev.value(hold, t: 0.5, T: 0.5) == .string("a"))
    }

    @Test func colorTokensInterpolate() {
        let ev = Evaluator(theme: ["fg": "#FFFFFF"])
        let p = Prop.keys([Keyframe(t: 0, v: "#000000"), Keyframe(t: 1, v: "$fg")])
        let c = RGBA.parse(ev.value(p, t: 0.5, T: 0.5))!
        #expect(abs(c.r - 0.5) < 1e-6)
    }

    @Test func expressions() {
        let ev = Evaluator()
        #expect(ev.value(.expr("t * 2"), t: 1.5, T: 1.5) == .number(3))
        #expect(ev.value(.expr("ease('linear', 0.25)"), t: 0, T: 0) == .number(0.25))
        #expect(ev.value(.expr("[t, 1]"), t: 2, T: 2) == [2, 1])
    }

    @Test func parentingAndTiming() {
        var s = Scene(id: "s", duration: 4)
        var child = Node(id: "c", type: "shape", parent: "g", props: ["x": .value(10)])
        child.start = 1
        s.nodes = [Node(id: "g", type: "group", props: ["x": .value(100), "opacity": .value(0.5)]), child]
        let ev = Evaluator()
        #expect(ev.evaluate(s, T: 0.5).map(\.node.id) == ["g"])
        let r = ev.evaluate(s, T: 2)
        let c = r.first { $0.node.id == "c" }!
        #expect(c.world.columns.3.x == 110)
        #expect(c.opacity == 0.5)
        #expect(c.t == 1)
    }

    @Test func countUpFormatting() {
        let n = EvalNode(
            node: Node(id: "t", type: "text"), world: matrix_identity_float4x4, opacity: 1, t: 0,
            props: ["text": "{v} people", "value": 1234567.4, "thousands": " "])
        #expect(Renderer.formatText(n) == "1 234 567 people")
    }
}

@Suite struct OpsTests {
    func scene() -> Scene {
        var s = Scene(id: "s")
        s.nodes = [
            Node(id: "g", type: "group"), Node(id: "a", type: "shape", parent: "g", props: ["x": .value(1)]),
            Node(id: "b", type: "shape"),
        ]
        return s
    }

    @Test func batchOps() throws {
        let ops: [JSONValue] = [
            ["op": "set", "id": "a", "x": 5, "fill": "#fff"],
            ["op": "set", "id": "a", "fill": .null],
            ["op": "key", "id": "b", "prop": "opacity", "keys": [[0, 0], [1, 1, "outCubic"]]],
            ["op": "add", "node": ["id": "c", "type": "shape"], "before": "g"],
            ["op": "duplicate", "id": "g", "as": "g2", "x": 100],
            ["op": "shift", "ids": ["b"], "by": 0.5],
            ["op": "scene", "duration": 8],
        ]
        let r = try SceneOps.apply(ops, to: scene())
        let s = r.scene
        #expect(s.node("a")?.props["x"] == .value(5) && s.node("a")?.props["fill"] == nil)
        guard case .keys(let ks)? = s.node("b")?.props["opacity"] else { Issue.record("no keys"); return }
        #expect(ks.count == 2)
        #expect(s.nodes.first?.id == "c")
        #expect(s.node("a-g2")?.parent == "g2")
        #expect(s.node("g2")?.props["x"] == .value(100))
        #expect(s.node("b")?.start == 0.5)
        #expect(s.duration == 8)
        #expect(Validator.validate(s).isEmpty)
    }

    @Test func removeTakesChildrenAndErrorsAreReported() throws {
        let r = try SceneOps.apply([["op": "remove", "id": "g"]], to: scene())
        #expect(r.scene.nodes.map(\.id) == ["b"])
        #expect(throws: (any Error).self) { try SceneOps.apply([["op": "set", "id": "zzz", "x": 1]], to: scene()) }
        #expect(throws: (any Error).self) {
            try SceneOps.apply([["op": "add", "node": ["id": "a", "type": "shape"]]], to: scene())
        }
    }

    @Test func historyAndRevert() throws {
        let project = try TempProject("history")
        defer { project.remove() }
        let store = project.store
        var s = try store.save(scene: scene(), summary: "create")
        s.nodes.removeAll()
        s = try store.save(scene: s, expectedRev: 1, summary: "clear")
        #expect(s.rev == 2)
        #expect(throws: (any Error).self) { try store.save(scene: s, expectedRev: 1) }
        let restored = try store.revert("s", to: 1)
        #expect(restored.rev == 3 && restored.nodes.count == 3)
        #expect(store.history("s").map(\.rev) == [1, 2, 3])
        #expect(try ProjectStore(url: project.url).scene("s").rev == 3)
    }
}

@Suite struct ThreeDTests {
    @Test func defaultCameraMatchesCanvas() {
        let cam = CameraState.make(nil, width: 1920, height: 1080)
        for p in [SIMD2<Float>(100, 200), SIMD2(1800, 1000), SIMD2(960, 540)] {
            let c = cam.viewProj * SIMD4(p.x, p.y, 0, 1)
            let px = (c.x / c.w + 1) / 2 * 1920, py = (1 - c.y / c.w) / 2 * 1080
            #expect(abs(px - p.x) < 0.05 && abs(py - p.y) < 0.05, "\(p) → \(px),\(py)")
        }
    }

    func node(_ props: [String: JSONValue]) -> EvalNode {
        EvalNode(
            node: Node(id: "c", type: "instancer"), world: matrix_identity_float4x4, opacity: 1, t: 1, props: props)
    }

    @Test func layouts() {
        let grid = InstanceLayout.positions(node(["cols": 4, "rows": 3, "spacing": 10]))
        #expect(grid.count == 12)
        #expect(abs(grid.map(\.x).reduce(0, +)) < 1e-3 && abs(grid.map(\.z).reduce(0, +)) < 1e-3)  // centred
        #expect(InstanceLayout.positions(node(["layout": "scatter", "count": 50])).count == 50)
        #expect(
            InstanceLayout.positions(node(["layout": "points", "points": [[1, 2], [3, 4, 5]]])) == [
                SIMD3(1, 0, 2), SIMD3(3, 4, 5),
            ])
    }

    @Test func perInstanceExpressions() {
        let ev = Evaluator()
        #expect(ev.expr.evalBatch("i * 2 + t", t: 1, T: 1, d: 5, n: 4) == [1, 3, 5, 7])
        let n = node(["cols": 10, "rows": 10, "instance": ["lit": ["expr": "i % 2 == 0"], "scale": 2]])
        let inst = InstanceLayout.build(
            n, items: [["glyph": "♟"], ["glyph": "♞", "weight": 3]], evaluator: ev, T: 1, duration: 5)
        #expect(inst.filter { $0.lit == 1 }.count == 50)
        #expect(inst.allSatisfy { $0.scale == 2 })
        let knights = inst.filter { $0.variant == 1 }.count
        #expect(knights > 55 && knights < 95)  // weight 3:1
    }

    @Test func vectorPieces() {
        for name in ChessPieces.names {
            guard let p = ChessPieces.make(name) else { Issue.record("\(name) missing"); continue }
            let b = p.bounds
            #expect(abs(b.minY) < 1e-6 && b.maxY > 0.85 && b.maxY < 1.05, "\(name) stands on the base, ~1 tall: \(b)")
            #expect(b.width > 0.3 && b.width < 0.8, "\(name) width \(b.width)")
            #expect(p.rim != nil, "\(name) has rim")
        }
        #expect(ChessPieces.make("dragon") == nil)
    }

    @Test func svgPaths() throws {
        // Relative commands, implicit lineto, H/V, cubic, quad, arc, close.
        let p = try SVGPath.parse("M0 0 h10 v10 H0 z m20 0 l5 5 5-5 C25 -5 30 -5 30 0 Q35 5 40 0 A5 5 0 0 1 50 0Z")
        let b = p.boundingBoxOfPath
        #expect(abs(b.minX) < 1e-6 && abs(b.maxX - 50) < 1e-3)
        #expect(b.minY < -3 && b.maxY >= 10)
        let s = try SVGPath.sprite(["path": "M-10 0 L10 0 L0 -40 Z", "rim": "M-5 -20 L5 -20"])
        // normalised, base at 0
        #expect(abs(s.bounds.height - 1) < 1e-6 && abs(s.bounds.minY) < 1e-6 && abs(s.bounds.midX) < 1e-6)
        #expect(s.rim != nil)
        #expect(throws: (any Error).self) { try SVGPath.parse("L 1 2") }
        #expect(throws: (any Error).self) { try SVGPath.parse("M 1 x") }
    }

    @Test(.requiresMetal) func atlasHasRimLayer() throws {
        let r = try Renderer()
        let a = SpriteAtlas.build(
            items: [["piece": "pawn"], ["glyph": "♞"], ["path": "M0 0 L10 0 L5 -20 Z"]],
            rasterHeight: 128, device: r.device, queue: r.queue, assets: nil)!
        #expect(a.cells.count == 3)
        #expect(a.cells[0].rimOffset == 0.5 && a.cells[1].rimOffset == 0 && a.cells[2].rimOffset == 0)
    }

    @Test(.requiresMetal) func rendersCrowdWithPoolsAndGrade() throws {
        var s = Scene(id: "s", duration: 2)
        s.camera = .value(["position": [960, -100, -400], "target": [960, 800, 1200], "dof": ["blur": 6]])
        s.post = .value(["vignette": 0.5, "grain": 0.03, "bloom": 0.5, "saturation": 0])
        s.nodes = [
            Node(
                id: "c", type: "instancer",
                props: [
                    "x": .value(960), "y": .value(800), "z": .value(1200), "cols": .value(12), "rows": .value(12),
                    "spacing": .value(80),
                    "items": .value([["glyph": "♟", "height": 60]]), "pool": .value(["radius": 30]),
                    "instance": .value(["lit": ["expr": "1"]]),
                ])
        ]
        let img = try Renderer().image(scene: s, project: Project(name: "t", size: [480, 270]), assets: nil, time: 1)
        let data = CFDataGetBytePtr(img.dataProvider!.data!)!
        var bright = 0
        for i in stride(from: 0, to: img.bytesPerRow * img.height, by: 4) where data[i + 1] > 180 { bright += 1 }
        #expect(bright > 200)
    }
}

@Suite struct E2EffectTests {
    @Test func pickChoosesExactShareInRandomOrder() {
        let e = ExprEngine()
        let ranks = e.evalBatch("pick(i, n, 0.45, 7)", t: 0, T: 0, d: 1, n: 1150)!
        let chosen = ranks.filter { $0 >= 0 }
        #expect(chosen.count == 518)  // round(1150 * 0.45)
        #expect(Set(chosen).count == 518 && chosen.max() == 517)  // ranks 0...517, each once
        #expect(Array(ranks.prefix(10)) != Array(ranks.prefix(10)).sorted())  // not in index order
    }

    @Test func lampFlickersThenHolds() {
        let e = ExprEngine()
        #expect(e.eval("lamp(t, 1)", t: 0.5, T: 0.5) == .number(0))
        #expect(e.eval("lamp(t, 1)", t: 2, T: 2) == .number(1))
        let early = (0..<16).map { e.eval("lamp(t, 0)", t: Double($0) * 0.01, T: 0).double! }
        #expect(early.contains { $0 < 0.4 } && early.contains { $0 > 0.5 })
    }

    @Test func counterReadsLiveLitCount() {
        var s = Scene(id: "s", duration: 5)
        s.nodes = [
            Node(
                id: "crowd", type: "instancer",
                props: [
                    "cols": .value(10), "rows": .value(10),
                    "instance": .value(["lit": ["expr": "i < t * 20 ? 1 : 0"]]),
                ]),
            Node(
                id: "c", type: "text",
                props: ["text": .value("{v}%"), "value": .expr("Math.round(100 * litFraction('crowd'))")]),
        ]
        let ev = Evaluator()
        #expect(ev.evaluate(s, T: 1).first { $0.node.id == "c" }?.props["value"] == .number(20))
        #expect(ev.evaluate(s, T: 2.5).first { $0.node.id == "c" }?.props["value"] == .number(50))
    }

    @Test func cameraShakeDecays() {
        let cam: JSONValue = ["shake": [["at": 1, "y": 10, "roll": 0]]]
        let base = CameraState.make(cam, width: 1920, height: 1080, time: 0.5).position
        let during = (1...10).map {
            CameraState.make(cam, width: 1920, height: 1080, time: 1 + Double($0) * 0.02).position.y - base.y
        }
        #expect(during.map(abs).max()! > 2)
        #expect(CameraState.make(cam, width: 1920, height: 1080, time: 2).position == base)
    }

    func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> UInt8 {
        CFDataGetBytePtr(img.dataProvider!.data!)![y * img.bytesPerRow + x * 4 + 1]
    }

    @Test(.requiresMetal) func gradientFillFadeAndMotionBlurRender() throws {
        var s = Scene(id: "s", duration: 2)
        s.background = .value("#000000")
        s.nodes = [
            Node(
                id: "g", type: "shape",
                props: [
                    "x": .value(200), "y": .value(50), "width": .value(400), "height": .value(100),
                    "fill": .value(["linear": [-200, 0, 200, 0], "stops": [[0, "#000000"], [1, "#FFFFFF"]]]),
                ])
        ]
        let p = Project(name: "t", size: [400, 100])
        let r = try Renderer()
        let img = try r.image(scene: s, project: p, assets: nil, time: 1)
        // Linear-light blend: 2.5% along is already ~sRGB 45, the midpoint ~188.
        #expect(
            pixel(img, 10, 50) < 60 && pixel(img, 390, 50) > 220 && pixel(img, 200, 50) > 150
                && pixel(img, 200, 50) < 220)
        s.post = .value(["fade": ["in": 0.5], "motionBlur": 3])
        #expect(pixel(try r.image(scene: s, project: p, assets: nil, time: 0), 390, 50) < 5)  // faded in from black
        #expect(pixel(try r.image(scene: s, project: p, assets: nil, time: 1), 390, 50) > 220)  // fully visible
    }
}

@Suite struct RenderTests {
    /// The shader source is split across three files; together they must stay exactly the library that was
    /// recorded (renders are compared against goldens made with it).
    @Test func shaderSourceIsUnchanged() {
        let hex = SHA256.hash(data: Array(ShaderSource.main.utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(hex == "790a0a1562cb6f9a40e080ec1c307d870501bd5454488fcc4563e053630300e1")
    }

    func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        let data = CFDataGetBytePtr(img.dataProvider!.data!)!
        let o = y * img.bytesPerRow + x * 4
        return (data[o + 2], data[o + 1], data[o], data[o + 3])  // BGRA → RGBA
    }

    @Test(.requiresMetal) func rendersShapeAndText() throws {
        var s = Scene(id: "s", duration: 1)
        s.background = .value("#000000")
        s.nodes = [
            Node(
                id: "r", type: "shape",
                props: [
                    "x": .value(50), "y": .value(50), "width": .value(40), "height": .value(40),
                    "fill": .value("#FF0000"),
                ]),
            Node(
                id: "t", type: "text",
                props: [
                    "text": .value("HELLO"), "x": .value(100), "y": .value(20), "size": .value(40),
                    "color": .value("#FFFFFF"),
                ]),
        ]
        var p = Project(name: "t", size: [320, 100])
        p.theme["display"] = "Helvetica-Bold"
        let img = try Renderer().image(scene: s, project: p, assets: nil, time: 0)
        #expect(img.width == 320)
        let c = pixel(img, 50, 50)
        #expect(c.0 == 255 && c.1 == 0 && c.2 == 0)
        #expect(pixel(img, 5, 5).0 == 0)
        // Some text pixels should be lit.
        var lit = 0
        for x in 100..<300 { for y in 20..<60 where pixel(img, x, y).0 > 128 { lit += 1 } }
        #expect(lit > 200)
    }

    /// Regression: sub-pixel lines vanished because AA used fwidth(d).
    @Test(.requiresMetal) func thinLineSurvivesDownscale() throws {
        var s = Scene(id: "s", duration: 1)
        s.nodes = [
            Node(
                id: "l", type: "shape",
                props: [
                    "shape": .value("line"), "x": .value(0), "y": .value(200),
                    "to": .value([800, 0]), "strokeWidth": .value(3), "stroke": .value("#FFFFFF"),
                ])
        ]
        let img = try Renderer().image(
            scene: s, project: Project(name: "t", size: [800, 400]), assets: nil, time: 0, scale: 0.25)
        let column = (45..<55).map { pixel(img, 100, $0).0 }
        #expect(column.max()! > 60)
    }
}
