import CoreGraphics
import Foundation
import Testing

@testable import ArclightCore

/// Standalone `symbol` layers: one symbol drawn as its own 2D layer.
@Suite struct SymbolLayerTests {
    private func scene(_ props: [String: Prop]) -> Scene {
        var s = Scene(id: "s", duration: 1)
        s.background = .value("#000000")
        s.nodes = [Node(id: "k", type: "symbol", props: props)]
        return s
    }

    @Test func schemaKnowsSymbolLayers() {
        #expect(Node.types.contains("symbol"))
        let n = Schema.node("symbol")
        #expect(n?.is3D == false)
        #expect(n?.fields.contains { $0.name == "symbol" } == true)
        #expect(Schema.markdown().contains("`symbol` — Symbol"))
        #expect(Schema.reference(type: "symbol").contains("size"))
    }

    @Test func validation() {
        let ok = scene(["symbol": .value("chess/knight"), "size": .value(300), "fill": .value("#FF0000")])
        #expect(Validator.validate(ok).isEmpty)
        let bad = scene(["symbol": .value("chess/dragon")])
        #expect(Validator.validate(bad).first?.message.contains("chess/knight") == true)  // lists what exists
        let wrongKind = scene(["size": .value("big")])
        #expect(!Validator.validate(wrongKind).isEmpty)
    }

    @Test func roundTrip() throws {
        let s = scene([
            "symbol": .value("basic/heart"), "size": .value(240), "x": .value(500),
            "opacity": .keys([Keyframe(t: 0, v: 0), Keyframe(t: 1, v: 1)]),
        ])
        let back = try JSONDecoder().decode(Scene.self, from: JSONEncoder().encode(s))
        #expect(back == s)
        #expect(back.nodes[0].type == "symbol")
        #expect(Schema.summary(back.nodes[0]).hasPrefix("heart · 240 px"))
    }

    @Test(.requiresMetal) func rendersOffscreen() throws {
        let r = try Renderer()
        let s = scene([
            "symbol": .value("chess/knight"), "size": .value(200), "x": .value(240), "y": .value(135),
            "fill": .value("#FFFFFF"),
        ])
        let img = try r.image(scene: s, project: Project(name: "t", size: [480, 270]), assets: nil, time: 0)
        let d = CFDataGetBytePtr(img.dataProvider!.data!)!
        var lit = 0, partial = 0
        for i in stride(from: 0, to: img.bytesPerRow * img.height, by: 4) {
            if d[i + 1] > 200 { lit += 1 } else if d[i + 1] > 20 { partial += 1 }
        }
        #expect(lit > 2000)  // a ~190 px tall knight
        #expect(partial > 50)  // anti-aliased edges
        let b = try #require(r.localBounds(r.evaluator.evaluate(s, T: 0)[0]))
        #expect(abs(b.midX) < 0.01 && abs(b.midY) < 0.01 && b.height > 150 && b.height <= 200)
    }

    @Test(.requiresMetal) func unknownSymbolDrawsNothing() throws {
        let s = scene(["symbol": .value("nope/x"), "size": .value(200), "x": .value(240), "y": .value(135)])
        let img = try Renderer().image(scene: s, project: Project(name: "t", size: [480, 270]), assets: nil, time: 0)
        let d = CFDataGetBytePtr(img.dataProvider!.data!)!
        var lit = 0
        for i in stride(from: 0, to: img.bytesPerRow * img.height, by: 4) where d[i + 1] > 20 { lit += 1 }
        #expect(lit == 0)
    }
}
