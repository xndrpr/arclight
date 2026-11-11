import CoreGraphics
import Foundation
import Testing

@testable import ArclightCore

@Suite struct SymbolTests {
    @Test func builtInSymbolsAllBuild() {
        let all = Symbols.all()
        #expect(all.contains { $0.id == "basic/person" } && all.contains { $0.id == "chess/knight" })
        for s in all {
            guard let sp = Symbols.sprite(s.id, project: nil) else { Issue.record("\(s.id) failed to build"); continue }
            let b = sp.bounds
            #expect(abs(b.minY) < 0.02, "\(s.id) stands on the floor: \(b)")
            #expect(b.height > 0.5 && b.height < 1.1 && b.width > 0.05, "\(s.id) bounds \(b)")
            #expect((sp.rim != nil) == s.hasRim, "\(s.id) rim flag")
        }
    }

    @Test func legacyNamesStillLoad() throws {
        let json = #"{"id":"c","type":"instancer","items":[{"piece":"pawn"}]}"#
        let n = try JSONDecoder().decode(Node.self, from: Data(json.utf8))
        #expect(n.type == "repeater")
        #expect(String(data: try JSONEncoder().encode(n), encoding: .utf8)!.contains(#""type":"repeater""#))
        var s = Scene(id: "s"); s.nodes = [n]
        #expect(Validator.validate(s).isEmpty)
        s.nodes[0].props["items"] = .value([["symbol": "basic/nope"]])
        #expect(Validator.validate(s).first?.message.contains("basic/person") == true)  // lists what exists
    }

    @Test func projectSymbolPacks() throws {
        let project = try TempProject("sym")
        let dir = project.url
        defer { project.remove() }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("symbols"), withIntermediateDirectories: true)
        try Data(
            #"{"pack":"brand","symbols":[{"id":"tri","name":"Triangle","path":"M-10 0 L10 0 L0 -20 Z","rim":"M-5 -10 L5 -10"}]}"#
                .utf8
        )
        .write(to: dir.appendingPathComponent("symbols/brand.json"))
        #expect(
            Symbols.all(project: dir).contains(
                Symbols.Info(id: "brand/tri", name: "Triangle", pack: "brand", hasRim: true)))
        #expect(Symbols.sprite("brand/tri", project: dir) != nil)
        #expect(Symbols.sprite("brand/tri", project: nil) == nil)
    }

    @Test(.requiresMetal) func defaultRepeaterIsNeutral() throws {
        var s = Scene(id: "s", duration: 1)
        s.background = .value("#000000")
        s.camera = .value(["position": [960, 200, -300], "target": [960, 800, 900]])
        s.nodes = [
            Node(
                id: "r", type: "repeater",
                props: [
                    "x": .value(960), "y": .value(800), "z": .value(900),
                    "cols": .value(6), "rows": .value(4), "spacing": .value(120),
                ])
        ]
        let img = try Renderer().image(scene: s, project: Project(name: "t", size: [480, 270]), assets: nil, time: 0)
        let d = CFDataGetBytePtr(img.dataProvider!.data!)!
        var bright = 0
        for i in stride(from: 0, to: img.bytesPerRow * img.height, by: 4) where d[i + 1] > 150 { bright += 1 }
        #expect(bright > 100)  // default items are $fg dots, visible on black (no hidden black-on-black chess)
    }
}
