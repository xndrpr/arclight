import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightMCP

@Suite struct SchemaTests {
    @Test func examplesValidateAgainstSchema() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let examples = try FileManager.default
            .contentsOfDirectory(at: root.appendingPathComponent("Examples"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "arclight" }
        #expect(!examples.isEmpty)
        for url in examples {
            let store = try ProjectStore(url: url)
            for s in store.orderedScenes {
                let issues = Validator.validate(s, expr: ExprEngine())
                #expect(issues.isEmpty, "\(url.lastPathComponent)/\(s.id): \(issues)")
            }
        }
    }

    @Test func typosGetSuggestions() {
        var s = Scene(id: "s")
        s.nodes = [
            Node(
                id: "t", type: "text",
                props: [
                    "text": .value("Hi"), "colour": .value("#fff"), "align": .value("centre"), "size": .value("big"),
                    "reveal": .value(["by": "word", "staggr": 0.1]), "_note": .value("custom data is fine"),
                ])
        ]
        let msgs = Validator.validate(s).map(\.message)
        #expect(msgs.contains { $0.contains("unknown property 'colour'") && $0.contains("did you mean 'color'") })
        #expect(msgs.contains { $0.contains("align must be one of") && $0.contains("'center'") })
        #expect(msgs.contains { $0.contains("size should be a number") })
        #expect(msgs.contains { $0.contains("reveal.staggr") && $0.contains("'stagger'") })
        #expect(!msgs.contains { $0.contains("_note") })
        #expect(msgs.count == 4)
    }

    @Test func keyframesAndTokensAndDisable() {
        var s = Scene(id: "s")
        s.camera = .keys([
            Keyframe(t: 0, v: ["position": [0, 0, -100], "fov": 40]), Keyframe(t: 1, v: ["fov": "wide"]),
        ])
        s.nodes = [
            Node(
                id: "r", type: "repeater",
                props: [
                    "ground": .value(false), "color": .value("$accent"),
                    "opacity": .keys([Keyframe(t: 0, v: 0), Keyframe(t: 1, v: 2)]),
                ])
        ]
        let msgs = Validator.validate(s).map(\.message)
        #expect(msgs.contains { $0.contains("camera@1s.fov should be a number") })
        #expect(msgs.contains { $0.contains("opacity@1s must be ≤ 1") })
        #expect(msgs.count == 2)
    }

    @Test func guideAndDocsCoverEveryType() {
        let all = Guide.all
        for n in Schema.nodes {
            #expect(all.contains("# \(n.type) — "), "guide covers \(n.type)")
            #expect(Schema.markdown().contains("## `\(n.type)`"))
        }
        #expect(Guide.topic("3d")?.contains("# repeater") == true)  // old topic names still work
        #expect(Guide.topic("symbols")?.contains("basic: person") == true)
    }

    @Test func summaries() {
        #expect(
            Schema.summary(Node(id: "a", type: "text", props: ["text": .value("45%"), "size": .value(300)]))
                == "“45%” · display 300")
        #expect(
            Schema.summary(
                Node(
                    id: "b", type: "shape",
                    props: ["shape": .value("ellipse"), "width": .value(160), "height": .value(48)]))
                == "Ellipse 160×48")
        let r = Node(
            id: "c", type: "repeater",
            props: [
                "cols": .value(40), "rows": .value(36), "items": .value([["symbol": "basic/person"]]),
                "pool": .value([:]), "opacity": .keys([Keyframe(t: 0, v: 0)]),
            ])
        #expect(Schema.summary(r) == "grid 40×36 · person · lit · ◆ opacity")
        #expect(Schema.summary(Node(id: "g", type: "group"), childCount: 3) == "3 layers")
    }
}
