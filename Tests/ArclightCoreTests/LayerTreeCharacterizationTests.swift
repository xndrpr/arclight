import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightEditor

/// Edge cases of `LayerTree` not covered by LayersTests: dangling parents, cycles, ordering, ungroup limits.
@Suite struct LayerTreeCharacterizationTests {
    func scene(_ nodes: [Node]) -> ArclightCore.Scene {
        var s = ArclightCore.Scene(id: "s", duration: 4)
        s.nodes = nodes
        return s
    }

    @Test func danglingAndSelfParentsCountAsRoot() {
        let s = scene([
            Node(id: "a", type: "shape", parent: "ghost"), Node(id: "b", type: "group", parent: "b"),
            Node(id: "c", type: "shape", parent: "b"),
        ])
        #expect(LayerTree.parent(s.nodes[0], in: s) == nil && LayerTree.parent(s.nodes[1], in: s) == nil)
        #expect(LayerTree.children(s)[""]?.map(\.id) == ["a", "b"])
        #expect(LayerTree.rows(s, selection: nil, pinned: false).map(\.id) == ["b", "c", "a"])
    }

    @Test func cyclesTerminate() {
        let s = scene([
            Node(id: "a", type: "group", parent: "b"), Node(id: "b", type: "group", parent: "a"),
            Node(id: "c", type: "shape", parent: "a"),
        ])
        #expect(LayerTree.ancestors(s, "c") == ["a", "b"])
        #expect(LayerTree.subtree(s, "a") == ["a", "b", "c"])
        // Neither group is a root, so nothing is listed.
        #expect(LayerTree.rows(s, selection: nil, pinned: false).isEmpty)
    }

    @Test func subtreeAndTopLevelKeepArrayOrder() {
        let s = scene([
            Node(id: "g", type: "group"), Node(id: "x", type: "shape"), Node(id: "a", type: "shape", parent: "g"),
            Node(id: "h", type: "group", parent: "g"), Node(id: "b", type: "shape", parent: "h"),
        ])
        #expect(LayerTree.subtree(s, "g") == ["g", "a", "h", "b"])
        #expect(LayerTree.topLevel(s, ["b", "h", "x"]) == ["x", "h"])
    }

    @Test func filterMatchesImageSourceAndTypeLabel() {
        let s = scene([
            Node(id: "pic", type: "image", props: ["src": .value("Logo.PNG")]),
            Node(id: "t", type: "text", props: ["text": .value("x")]),
        ])
        #expect(LayerTree.rows(s, selection: nil, filter: "logo", pinned: false).map(\.id) == ["pic"])
        #expect(LayerTree.rows(s, selection: nil, filter: "  ", pinned: false).map(\.id) == ["t", "pic"])
    }

    @Test func pinnedRowsCarryCameraAndLookKeys() {
        var s = scene([])
        s.camera = .keys([Keyframe(t: 0, v: ["fov": 30]), Keyframe(t: 1, v: ["fov": 40])])
        s.fog = .value(["near": 1])
        let rows = LayerTree.rows(s, selection: LayerTree.lookId)
        #expect(rows.map(\.id) == ["@camera", "@look"])  // static fog: no sub-row; the camera row shows its own keys
        #expect(LayerTree.rows(s, selection: LayerTree.cameraId).map(\.id) == ["@camera", "@look"])
        #expect(LayerTree.lookSummary(s) == "fog")
        #expect(LayerTree.cameraSummary(s) == "fov 30 · moving")
        s.post = .value(["saturation": 0.5, "contrast": 1.2, "exposure": 0.1, "vignette": 0, "fade": ["in": 0.5]])
        #expect(LayerTree.lookSummary(s) == "sat 0.5 · contrast · exposure · fade · fog")
        s.camera = .expr("x")
        #expect(LayerTree.cameraSummary(s) == "expression")
    }

    @Test func ungroupDoesNotBakeTransformsItCannotPreserve() {
        let s = scene([
            Node(id: "outer", type: "group"),
            Node(id: "g", type: "group", parent: "outer", props: ["x": .value(10), "rotation": .value(15)]),
            Node(id: "a", type: "shape", parent: "g", props: ["x": .value(1)]),
        ])
        let ops = LayerTree.ungroupOps(s, groups: ["g"])
        // Rotated group: children keep their own x; they move to the group's parent.
        #expect(ops == [["op": "set", "id": "a", "parent": "outer"], ["op": "remove", "id": "g"]])
        // An expression on the child is left alone, a missing prop gets the offset.
        let t = scene([
            Node(id: "g", type: "group", props: ["x": .value(10), "y": .value(0)]),
            Node(id: "a", type: "shape", parent: "g", props: ["x": .expr("t")]),
        ])
        #expect(
            LayerTree.ungroupOps(t, groups: ["g"]) == [
                ["op": "set", "id": "a", "parent": .null], ["op": "remove", "id": "g"],
            ])
        let u = scene([
            Node(id: "g", type: "group", props: ["x": .value(10)]), Node(id: "a", type: "shape", parent: "g"),
        ])
        #expect(
            LayerTree.ungroupOps(u, groups: ["g"]) == [
                ["op": "set", "id": "a", "parent": .null, "x": 10], ["op": "remove", "id": "g"],
            ])
    }

    @Test func groupAcrossParentsGoesToRoot() {
        let s = scene([
            Node(id: "g", type: "group"), Node(id: "a", type: "shape", parent: "g"), Node(id: "b", type: "shape"),
        ])
        let ops = LayerTree.groupOps(s, ids: ["a", "b", "missing"], groupId: "new")
        #expect(
            ops == [
                ["op": "add", "node": ["id": "new", "type": "group"], "after": "b"],
                ["op": "set", "ids": ["a", "b"], "parent": "new"],
            ])
        #expect(LayerTree.groupOps(s, ids: ["missing"], groupId: "new").isEmpty)
    }
}
