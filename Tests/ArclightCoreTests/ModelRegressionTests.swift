import Foundation
import Testing

@testable import ArclightCore

// Regression tests for the scene-model bugs found in the 0.1.0 release work (schema, validation, evaluator, colours,
// expressions, Doctor), plus the E2 check that showed it was not a bug.

@Suite struct ModelRegressionTests {
    private static let theme: [String: JSONValue] = [
        "bg": "#000000", "fg": "#F2EFE6", "muted": "#7A7A7A", "accent": "#336699", "ink": "#102030",
        "display": "HelveticaNeue-CondensedBlack", "body": "HelveticaNeue-Medium",
    ]

    private func rgb(_ v: JSONValue?) -> RGBA? { RGBA.parse(v) }

    private func nearRGBA(_ c: RGBA?, _ r: Double, _ g: Double, _ b: Double, _ a: Double) -> Bool {
        guard let c else { return false }
        return near(c.r, r, 1e-3) && near(c.g, g, 1e-3) && near(c.b, b, 1e-3) && near(c.a, a, 1e-3)
    }

    /// A project in a temp folder with one scene and the test theme.
    private func project(_ build: (inout ArclightCore.Scene) -> Void) throws -> TempProject {
        let p = try TempProject("model-regression")
        var pr = p.store.project
        pr.theme = Self.theme
        try p.store.update(project: pr)
        var s = ArclightCore.Scene(id: "s", duration: 2)
        build(&s)
        try p.store.save(scene: s)
        return p
    }

    // MARK: E3

    /// E3: `pool.intensity` given as keyframes `{"k": [...]}` on a light layer validates and interpolates.
    @Test func e3_nestedLightIntensityCanBeKeyframed() throws {
        let pool: JSONValue = ["radius": 200, "intensity": ["k": [[0, 0], [2, 2]]]]
        let beam: JSONValue = ["height": 900, "intensity": ["k": [[0, 0.2], [2, 0.6]]]]
        var scene = ArclightCore.Scene(id: "s", duration: 2)
        scene.nodes = [Node(id: "lamp", type: "light", props: ["pool": .value(pool), "beam": .value(beam)])]
        let issues = Validator.validate(scene)
        let ev = Evaluator(theme: Self.theme)
        let mid = try #require(ev.evaluate(scene, T: 1).first)
        #expect(issues.isEmpty, "\(issues)")
        #expect(mid.props["pool"]?["intensity"]?.double == 1)
        #expect(near(mid.props["beam"]?["intensity"]?.double ?? -1, 0.4))
        #expect(mid.props["pool"]?["radius"]?.double == 200)
        // Keyframe values are checked like plain ones; easing and tokens work as on any prop.
        let eased: JSONValue = ["intensity": ["k": [[0, 0], [2, "$two", "outCubic"]]]]
        let bad: JSONValue = ["intensity": ["k": [[0, 0], [1, -1]]], "radius": ["k": [[0, "big"]]]]
        var s2 = ArclightCore.Scene(id: "s", duration: 2)
        s2.nodes = [
            Node(id: "a", type: "light", props: ["pool": .value(eased)]),
            Node(id: "b", type: "light", props: ["pool": .value(bad)]),
        ]
        #expect(
            Validator.validate(s2).map(\.description) == [
                "b: pool.intensity@1s must be ≥ 0 (got -1)", "b: pool.radius@0s should be a number, got \"big\"",
            ])
        let ev2 = Evaluator(theme: Self.theme.merging(["two": 2]) { a, _ in a })
        let a1 = try #require(ev2.evaluate(s2, T: 1).first { $0.node.id == "a" })
        #expect(near(a1.props["pool"]?["intensity"]?.double ?? -1, 2 * Easing("outCubic").apply(0.5)))
    }

    /// E3: only number settings inside a layer's object settings take nested keyframes; `{"k": …}` elsewhere
    /// (a JSON field, custom data, a text field, a list item, scene settings) is left alone.
    @Test func e3_nestedKeyframesOnlyForNumberSettings() throws {
        let k: JSONValue = ["k": [[0, 0], [2, 2]]]
        var scene = ArclightCore.Scene(id: "s", duration: 2)
        scene.post = .value(["bloom": ["intensity": k]])
        scene.nodes = [
            Node(
                id: "r", type: "repeater",
                props: ["points": .value(["k": k]), "_data": .value(["k": k]), "items": .value([["weight": k]])]),
            Node(id: "t", type: "text", props: ["text": .value("Hi"), "reveal": .value(["by": k])]),
        ]
        let ev = Evaluator(theme: Self.theme)
        let out = ev.evaluate(scene, T: 1)
        let r = try #require(out.first { $0.node.id == "r" })
        #expect(r.props["points"] == ["k": k])
        #expect(r.props["_data"] == ["k": k])
        #expect(r.props["items"] == [["weight": k]])
        #expect(out.first { $0.node.id == "t" }?.props["reveal"] == ["by": k])
        #expect(ev.sceneValue(scene.post, scene, T: 1) == ["bloom": ["intensity": k]])
        let issues = Validator.validate(scene).map(\.description)
        #expect(issues.contains { $0.contains("post.bloom.intensity") }, "\(issues)")
        #expect(issues.contains { $0.contains("reveal.by") }, "\(issues)")
    }

    // MARK: E9

    /// E9: `"$token@NN"` is a token colour with NN % alpha, accepted wherever a colour is.
    @Test func e9_tokenWithAlphaResolvesAndIsNotFlagged() throws {
        let ev = Evaluator(theme: Self.theme)
        let c = 255.0
        let expected = (0x33 / c, 0x66 / c, 0x99 / c)
        #expect(nearRGBA(rgb(ev.resolve("$accent@25")), expected.0, expected.1, expected.2, 0.25))
        #expect(nearRGBA(rgb(ev.resolve("$accent@100")), expected.0, expected.1, expected.2, 1))
        #expect(nearRGBA(rgb(ev.resolve("$accent@0")), expected.0, expected.1, expected.2, 0))
        #expect(ev.resolve("$accent@25") == "#33669940")
        // The alpha replaces the token's own; chained tokens resolve first; names and arrays work too.
        let more = Evaluator(
            theme: Self.theme.merging(
                ["glass": "#33669980", "link": "$accent", "white": "white", "arr": [1, 0, 0], "odd@50": "#FF0000"]
            ) { a, _ in a })
        #expect(more.resolve("$glass@100") == "#336699FF")
        #expect(more.resolve("$link@50") == "#33669980")
        #expect(more.resolve("$white@50") == "#FFFFFF80")
        #expect(more.resolve("$arr@20") == "#FF000033")
        // A theme key containing "@" wins; anything that isn't a token colour with 0–100 stays as written.
        #expect(more.resolve("$odd@50") == "#FF0000")
        for s in ["$accent@101", "$accent@", "$accent@+5", "$accent@2.5", "$@50", "$display@50", "$nosuch@50"] {
            #expect(more.resolve(.string(s)) == .string(s), "\(s)")
        }

        // Gradient stops: both stops must survive, the first at alpha 0.25.
        let fill: JSONValue = ["linear": [0, 0, 100, 0], "stops": [[0, "$accent@25"], [1, "$fg"]]]
        let shape = Node(id: "sh", type: "shape", props: ["fill": .value(fill)])
        var scene = ArclightCore.Scene(id: "s", duration: 2)
        scene.nodes = [shape]
        let resolved = try #require(ev.evaluate(scene, T: 0).first)
        let grad = GradientFill(resolved.props["fill"], opacity: 1)
        #expect(grad?.info.y == 2)
        #expect(near(Double(grad?.colors[0].w ?? -1), 0.25, 1e-3))

        // Validation accepts it (any "$" string passes) and Doctor must not call it an unknown token.
        let p = try project { s in
            s.post = .value(["fade": ["in": 0.3, "color": "$accent@25"]])
            s.nodes = [
                Node(id: "t", type: "text", props: ["text": .value("Hi"), "color": .value("$accent@25")]),
                shape,
            ]
        }
        defer { p.remove() }
        let store = try ProjectStore(url: p.url)
        let issues = Validator.validate(try #require(store.orderedScenes.first))
        #expect(issues.isEmpty, "\(issues)")
        let problems = Doctor.check(store)
        #expect(problems.filter { $0.kind == "token" }.isEmpty, "\(Doctor.report(problems))")

        // An unknown token with alpha is reported by its token name.
        let q = try project { s in
            s.nodes = [Node(id: "t", type: "text", props: ["text": .value("Hi"), "color": .value("$nosuch@25")])]
        }
        defer { q.remove() }
        let missing = Doctor.check(try ProjectStore(url: q.url)).filter { $0.kind == "token" }.map(\.message)
        #expect(missing == ["uses $nosuch, which is not in the theme"])
    }

    // MARK: E2

    /// E2: `post.fade.color` accepts theme tokens (resolved by the evaluator) and Doctor flags unknown ones.
    ///
    /// Not reproducible on the model side: `Renderer.grade` reads the already-resolved `post` from
    /// `Evaluator.sceneValue` (which resolves tokens recursively), and `Doctor` scans `scene.post` recursively.
    /// `Renderer.grade` itself needs Metal, so the nearest reachable surface is `sceneValue`.
    @Test func e2_postFadeColorTokenResolvesAndDoctorFlagsUnknown() throws {
        var scene = ArclightCore.Scene(id: "s", duration: 2)
        scene.post = .value(["fade": ["in": 0.3, "color": "$ink"]])
        let ev = Evaluator(theme: Self.theme)
        let post = try #require(ev.sceneValue(scene.post, scene, T: 0)?.object)
        #expect(nearRGBA(rgb(post["fade"]?["color"]), 0x10 / 255.0, 0x20 / 255.0, 0x30 / 255.0, 1))

        let p = try project { s in s.post = .value(["fade": ["out": 0.4, "color": "$nosuch"]]) }
        defer { p.remove() }
        let problems = Doctor.check(try ProjectStore(url: p.url))
        #expect(problems.contains { $0.kind == "token" && $0.message.contains("$nosuch") }, "\(problems)")
    }

    // MARK: B10

    /// B10: an expression is classified by parsing, not by containing the text "return".
    @Test func b10_returnInsideAStringOrPropertyNameIsStillAnExpression() {
        let e = ExprEngine()
        // Statement bodies keep working.
        #expect(e.eval("return 1+1", t: 0, T: 0) == .number(2))
        #expect(e.eval("var x = t * 2; return x + 1", t: 3, T: 0) == .number(7))
        #expect(e.evalBatch("var k = i; return k * 10", t: 0, T: 0, d: 0, n: 3) == [0, 10, 20])
        #expect(e.eval("'return'.length", t: 0, T: 0) == .number(6))
        #expect(e.eval("({returnValue: 3}).returnValue", t: 0, T: 0) == .number(3))
        #expect(e.evalBatch("'return'.length", t: 0, T: 0, d: 0, n: 2) == [6, 6])
    }

    // MARK: DOC-1

    /// DOC-1: Doctor's `kind` follows the problem's origin, not whether the message text contains "Error".
    @Test func doc1_doctorKindDoesNotDependOnTheWordError() throws {
        let p = try project { s in
            s.nodes = [
                // A schema problem whose message contains "Error" (a symbol called ErrorBadge).
                Node(id: "badge", type: "symbol", props: ["symbol": .value("basic/ErrorBadge")]),
                // A real expression failure whose message lacks "Error" (the thrown value is the message).
                Node(
                    id: "ex", type: "shape", props: ["x": .expr("var a = t; if (a == 0) { throw 'boom'; } return a;")]),
            ]
        }
        defer { p.remove() }
        let problems = Doctor.check(try ProjectStore(url: p.url))
        let badge = try #require(problems.first { $0.node == "badge" && $0.message.contains("ErrorBadge") })
        let boom = try #require(problems.first { $0.node == "ex" && $0.message.contains("boom") })
        #expect(badge.kind == "schema")
        #expect(boom.kind == "expression")
    }
}
