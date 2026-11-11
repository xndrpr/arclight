import Foundation
import Testing

@testable import ArclightCore

/// Pins the current behaviour of every `SceneOps` op and editor helper, so refactors can't change it unnoticed.
@Suite struct SceneOpsCharacterizationTests {
    /// Draw order bottom → top: g{a, b{c}}, d.
    func scene() -> ArclightCore.Scene {
        var s = ArclightCore.Scene(id: "s", duration: 4)
        s.nodes = [
            Node(id: "g", type: "group"),
            Node(id: "a", type: "shape", parent: "g", props: ["x": .value(1)]),
            Node(id: "b", type: "group", parent: "g"),
            Node(id: "c", type: "text", parent: "b", props: ["text": .value("Hi")]),
            Node(id: "d", type: "shape"),
        ]
        return s
    }

    func apply(_ ops: [JSONValue], to s: ArclightCore.Scene? = nil) throws -> SceneOps.Result {
        try SceneOps.apply(ops, to: s ?? scene())
    }

    func ids(_ s: ArclightCore.Scene) -> [String] { s.nodes.map(\.id) }

    func message(_ ops: [JSONValue]) -> String {
        do { _ = try apply(ops); return "" } catch { return "\(error)" }
    }

    // MARK: add / move

    @Test func addInsertsOnTopOrRelative() throws {
        #expect(ids(try apply([["op": "add", "node": ["id": "n", "type": "shape"]]]).scene).last == "n")
        #expect(
            ids(try apply([["op": "add", "node": ["id": "n", "type": "shape"], "after": "a"]]).scene) == [
                "g", "a", "n", "b", "c", "d",
            ])
        #expect(ids(try apply([["op": "add", "node": ["id": "n", "type": "shape"], "index": -3]]).scene).first == "n")
        #expect(ids(try apply([["op": "add", "node": ["id": "n", "type": "shape"], "index": 99]]).scene).last == "n")
        // Old type names are rewritten on the way in.
        #expect(
            try apply([["op": "add", "node": ["id": "r", "type": "instancer"]]]).scene.node("r")?.type == "repeater")
    }

    @Test func moveByIndexBeforeAfter() throws {
        #expect(ids(try apply([["op": "move", "id": "d", "index": 0]]).scene) == ["d", "g", "a", "b", "c"])
        #expect(ids(try apply([["op": "move", "id": "g", "after": "d"]]).scene) == ["a", "b", "c", "d", "g"])
        #expect(ids(try apply([["op": "move", "id": "d", "before": "a"]]).scene) == ["g", "d", "a", "b", "c"])
        // Move only moves the node itself, never its children.
        #expect(ids(try apply([["op": "move", "id": "b", "index": 0]]).scene) == ["b", "g", "a", "c", "d"])
    }

    // MARK: set / key

    @Test func setMergesPropsAndMeta() throws {
        let s = try apply([
            ["op": "set", "ids": ["a", "d"], "y": 7, "name": "Named", "in": 0.5, "out": 3],
            ["op": "set", "id": "a", "x": .null, "type": "instancer", "parent": .null],
        ]).scene
        #expect(s.node("d")?.props["y"] == .value(7) && s.node("d")?.name == "Named")
        #expect(s.node("d")?.start == 0.5 && s.node("d")?.end == 3)
        #expect(s.node("a")?.props["x"] == nil && s.node("a")?.type == "repeater" && s.node("a")?.parent == nil)
        // Keyframes and expressions are parsed from their JSON forms.
        let k = try apply([["op": "set", "id": "a", "x": ["k": [[1, 10], [0, 0]]], "y": ["expr": "t*2"]]]).scene.node(
            "a")
        #expect(k?.props["x"] == .keys([Keyframe(t: 0, v: 0), Keyframe(t: 1, v: 10)]))
        #expect(k?.props["y"] == .expr("t*2"))
    }

    @Test func keyMergesByTimeOrReplaces() throws {
        // A constant becomes the key at t = 0.
        let merged = try apply([["op": "key", "id": "a", "prop": "x", "keys": [[1, 5, "outCubic"]]]]).scene.node("a")?
            .props["x"]
        #expect(merged == .keys([Keyframe(t: 0, v: 1), Keyframe(t: 1, v: 5, ease: .named("outCubic"))]))
        // Same time replaces that key; others stay.
        let base = try apply([["op": "key", "id": "a", "prop": "x", "keys": [[0, 0], [2, 2]]]]).scene
        let again = try apply([["op": "key", "id": "a", "prop": "x", "keys": [[2, 9]]]], to: base).scene.node("a")?
            .props["x"]
        #expect(again == .keys([Keyframe(t: 0, v: 0), Keyframe(t: 2, v: 9)]))
        let replaced = try apply([["op": "key", "id": "a", "prop": "x", "keys": [[3, 3]], "replace": true]], to: base)
            .scene
        #expect(replaced.node("a")?.props["x"] == .keys([Keyframe(t: 3, v: 3)]))
        // An expression is dropped when keys are merged in (it has no value at t = 0).
        let ex = try apply([
            ["op": "set", "id": "a", "x": ["expr": "t"]], ["op": "key", "id": "a", "prop": "x", "keys": [[1, 1]]],
        ]).scene
        #expect(ex.node("a")?.props["x"] == .keys([Keyframe(t: 1, v: 1)]))
    }

    // MARK: remove / duplicate / shift

    @Test func removeTakesDescendants() throws {
        let r = try apply([["op": "remove", "id": "g"]])
        #expect(ids(r.scene) == ["d"])
        // `changed` comes from a Set: its order is not stable, only its contents.
        #expect(Set(r.changed) == ["g", "a", "b", "c"])
    }

    @Test func duplicateCopiesSubtreeWithRenamedIds() throws {
        let r = try apply([["op": "duplicate", "id": "g", "as": "g2", "x": 50, "after": "d"]])
        #expect(ids(r.scene) == ["g", "a", "b", "c", "d", "g2", "a-g2", "b-g2", "c-g2"])
        #expect(r.scene.node("g2")?.props["x"] == .value(50) && r.scene.node("g2")?.parent == nil)
        #expect(r.scene.node("a-g2")?.parent == "g2" && r.scene.node("c-g2")?.parent == "b-g2")
        #expect(r.changed == ["g2", "a-g2", "b-g2", "c-g2"])
        // Without a position the copies go on top of everything.
        #expect(ids(try apply([["op": "duplicate", "id": "d", "as": "d2"]]).scene).last == "d2")
    }

    @Test func shiftMovesInAndOutPoints() throws {
        var s = scene()
        s.nodes[4].end = 2
        let r = try apply([["op": "shift", "ids": ["a", "d"], "by": 0.5]], to: s).scene
        #expect(r.node("a")?.start == 0.5 && r.node("a")?.end == nil)
        #expect(r.node("d")?.start == 0.5 && r.node("d")?.end == 2.5)
    }

    // MARK: scene / marker

    @Test func sceneFieldsAndNulls() throws {
        var s = scene()
        s.fog = .value(["near": 1])
        let r = try apply(
            [
                [
                    "op": "scene", "duration": 6, "name": "Intro", "fps": 25, "size": [1080, 1920],
                    "background": "#111", "fog": .null, "audio": ["src": "vo.wav"],
                ]
            ], to: s)
        #expect(r.changed.isEmpty)
        #expect(r.scene.duration == 6 && r.scene.name == "Intro" && r.scene.fps == 25 && r.scene.size == [1080, 1920])
        #expect(r.scene.background == .value("#111") && r.scene.fog == nil && r.scene.audio?.src == "vo.wav")
        let cleared = try apply([["op": "scene", "audio": .null, "name": .null]], to: r.scene).scene
        #expect(cleared.audio == nil && cleared.name == nil)
    }

    @Test func markersAddMoveRemoveSorted() throws {
        let s = try apply([
            ["op": "marker", "name": "b", "t": 2],
            ["op": "marker", "name": "a", "t": 1, "color": "#FC0"],
            ["op": "marker", "name": "b", "t": 0.5],
        ]).scene
        #expect(s.markers?.map(\.name) == ["b", "a"] && s.markers?.map(\.t) == [0.5, 1])
        #expect(s.markers?.last?.color == "#FC0")
        let gone = try apply(
            [["op": "marker", "name": "a", "remove": true], ["op": "marker", "name": "b", "remove": true]], to: s
        ).scene
        #expect(gone.markers == nil)
    }

    // MARK: Results and errors

    @Test func summaryAndChangedAreDeduplicated() throws {
        let r = try apply([
            ["op": "set", "id": "a", "x": 2], ["op": "set", "ids": ["a", "d", "c", "g"], "y": 1],
            ["op": "scene", "duration": 5],
        ])
        #expect(r.changed == ["a", "d", "c", "g"])
        #expect(r.summary == "set a; set a,d,c…; scene ")
    }

    @Test func errorMessagesNameTheOp() {
        #expect(message([["x": 1]]) == "op 0: missing 'op'")
        #expect(
            message([["op": "set", "id": "a", "x": 1], ["op": "zap"]])
                == "op 1 (zap): unknown op (add, set, key, remove, move, duplicate, shift, scene, marker)")
        #expect(message([["op": "set", "id": "nope", "x": 1]]) == "op 0 (set): not found: node 'nope'")
        #expect(message([["op": "set", "x": 1]]) == "op 0 (set): needs 'id' or 'ids'")
        #expect(message([["op": "add", "node": ["id": "d", "type": "shape"]]]) == "op 0 (add): id 'd' already exists")
        #expect(message([["op": "duplicate", "id": "a", "as": "d"]]) == "op 0 (duplicate): id 'd' already exists")
        #expect(message([["op": "shift", "id": "a"]]) == "op 0 (shift): needs 'by' (seconds)")
        #expect(message([["op": "marker", "name": "m"]]) == "op 0 (marker): needs 't' (seconds)")
        // A failing op leaves the input untouched (ops apply to a copy).
        let s = scene()
        _ = try? SceneOps.apply([["op": "remove", "id": "d"], ["op": "zap"]], to: s)
        #expect(ids(s) == ["g", "a", "b", "c", "d"])
    }

    // MARK: Editor helpers

    @Test func setPropAutoKeysWhenAnimated() {
        var s = scene()
        SceneOps.setProp(&s, id: "a", prop: "x", value: 9, localTime: 1)
        #expect(s.node("a")?.props["x"] == .value(9))
        s.nodes[1].props["x"] = .keys([Keyframe(t: 0, v: 0, ease: .named("outCubic"))])
        SceneOps.setProp(&s, id: "a", prop: "x", value: 5, localTime: 1.00049)
        #expect(
            s.node("a")?.props["x"]
                == .keys([
                    Keyframe(t: 0, v: 0, ease: .named("outCubic")), Keyframe(t: 1, v: 5, ease: .named("outCubic")),
                ]))
        // Within 0.1 ms of a key: replaces it (and its ease when given).
        SceneOps.setProp(&s, id: "a", prop: "x", value: 6, localTime: 1.00004, ease: .named("linear"))
        #expect(s.node("a")?.props["x"]?.keyCount == 2)
        guard case .keys(let ks)? = s.node("a")?.props["x"] else { Issue.record("not keys"); return }
        #expect(ks[1].v == 6 && ks[1].ease == .named("linear"))
        // An expression is replaced by the value.
        s.nodes[1].props["y"] = .expr("t")
        SceneOps.setProp(&s, id: "a", prop: "y", value: 3, localTime: 0)
        #expect(s.node("a")?.props["y"] == .value(3))
    }

    @Test func toggleKeyAddsAndRemoves() {
        var s = scene()
        SceneOps.toggleKey(&s, id: "a", prop: "x", current: 1, localTime: 0.5)
        #expect(s.node("a")?.props["x"] == .keys([Keyframe(t: 0.5, v: 1)]))
        SceneOps.toggleKey(&s, id: "a", prop: "x", current: 2, localTime: 1.5)
        #expect(s.node("a")?.props["x"]?.keyCount == 2)
        SceneOps.toggleKey(&s, id: "a", prop: "x", current: 2, localTime: 1.5)
        SceneOps.toggleKey(&s, id: "a", prop: "x", current: 7, localTime: 0.5)
        // The last key removed leaves the current value as a constant.
        #expect(s.node("a")?.props["x"] == .value(7))
    }

    @Test func uniqueIdCountsUp() {
        var s = scene()
        #expect(SceneOps.uniqueId("new", in: s) == "new")
        #expect(SceneOps.uniqueId("a", in: s) == "a-2")
        s.nodes.append(Node(id: "a-2", type: "shape"))
        #expect(SceneOps.uniqueId("a", in: s) == "a-3")
    }
}
