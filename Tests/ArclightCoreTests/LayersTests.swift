import AppKit
import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightEditor

/// Layer list logic: rows, filter, range select, reorder / re-parent, group / ungroup, lock.
@Suite(.serialized) struct LayersTests {
    /// Draw order bottom → top: bg, pools(group){p1, p2}, title.
    func scene() -> ArclightCore.Scene {
        var s = ArclightCore.Scene(id: "s", duration: 4)
        s.nodes = [
            Node(id: "bg", type: "shape", props: ["shape": .value("rect")]),
            Node(id: "pools", type: "group", props: ["x": .value(100), "y": .value(50)]),
            Node(id: "p1", type: "shape", parent: "pools", props: ["shape": .value("ellipse"), "x": .value(10)]),
            Node(
                id: "p2", type: "shape", parent: "pools",
                props: [
                    "shape": .value("ellipse"),
                    "x": .keys([Keyframe(t: 0, v: 0), Keyframe(t: 1, v: 20)]),
                ]),
            Node(id: "title", type: "text", props: ["text": .value("Hello world")]),
        ]
        return s
    }

    func run(_ s: ArclightCore.Scene, _ ops: [JSONValue]) throws -> ArclightCore.Scene {
        try SceneOps.apply(ops, to: s).scene
    }
    func ids(_ s: ArclightCore.Scene) -> [String] { s.nodes.map(\.id) }

    @Test func rowsHierarchyCollapseAndPinned() {
        let s = scene()
        #expect(
            LayerTree.rows(s, selection: nil).map(\.id) == ["@camera", "@look", "title", "pools", "p2", "p1", "bg"])
        #expect(LayerTree.rows(s, selection: nil).first { $0.id == "p1" }?.depth == 1)
        #expect(
            LayerTree.rows(s, selection: nil, collapsed: ["pools"], pinned: false).map(\.id) == [
                "title", "pools", "bg",
            ])
        // Selected layer's animated props follow it.
        #expect(
            LayerTree.rows(s, selection: "p2", pinned: false).map(\.id) == ["title", "pools", "p2", "p2.x", "p1", "bg"])
    }

    @Test func filterMatchesNameTypeTextAndKeepsAncestors() {
        var s = scene()
        s.nodes[2].name = "Left pool"
        #expect(LayerTree.rows(s, selection: nil, filter: "left", pinned: false).map(\.id) == ["pools", "p1"])
        #expect(LayerTree.rows(s, selection: nil, filter: "WORLD", pinned: false).map(\.id) == ["title"])
        #expect(LayerTree.rows(s, selection: nil, filter: "ellipse", pinned: false).map(\.id) == ["pools", "p2", "p1"])
        // Filtering ignores collapse; pinned rows only when they match.
        #expect(LayerTree.rows(s, selection: nil, collapsed: ["pools"], filter: "p2").map(\.id) == ["pools", "p2"])
        #expect(LayerTree.rows(s, selection: nil, filter: "camera").map(\.id) == ["@camera"])
    }

    @Test func rangeSelectInVisualOrder() {
        let order = LayerTree.visualOrder(LayerTree.rows(scene(), selection: nil))
        #expect(order == ["title", "pools", "p2", "p1", "bg"])
        #expect(LayerTree.rangeSelect(order: order, anchor: "p1", to: "title") == ["title", "pools", "p2", "p1"])
        #expect(LayerTree.rangeSelect(order: order, anchor: "pools", to: "bg") == ["pools", "p2", "p1", "bg"])
        #expect(LayerTree.rangeSelect(order: order, anchor: nil, to: "bg") == ["bg"])
    }

    @Test func reorderAndReparent() throws {
        let s = scene()
        // Drop title below bg (bottom of the stack).
        #expect(
            ids(try run(s, LayerTree.moveOps(s, ids: ["title"], drop: .below("bg")))) == [
                "title", "bg", "pools", "p1", "p2",
            ])
        // Drop bg above title: moves to the top.
        #expect(
            ids(try run(s, LayerTree.moveOps(s, ids: ["bg"], drop: .above("title")))) == [
                "pools", "p1", "p2", "title", "bg",
            ])
        // Moving a group carries its children.
        #expect(
            ids(try run(s, LayerTree.moveOps(s, ids: ["pools"], drop: .above("title")))) == [
                "bg", "title", "pools", "p1", "p2",
            ])
        // Into a group: re-parented on top of its children.
        let into = try run(s, LayerTree.moveOps(s, ids: ["title"], drop: .into("pools")))
        #expect(into.node("title")?.parent == "pools" && ids(into) == ["bg", "pools", "p1", "p2", "title"])
        // Out of a group, next to a root layer.
        let out = try run(s, LayerTree.moveOps(s, ids: ["p1"], drop: .above("title")))
        #expect(out.node("p1")?.parent == nil && ids(out).last == "p1")
        // Can't drop a group into itself or its children.
        #expect(LayerTree.moveOps(s, ids: ["pools"], drop: .into("pools")).isEmpty)
        #expect(LayerTree.moveOps(s, ids: ["pools"], drop: .below("p1")).isEmpty)
        // Bring forward / send backward swap with siblings only.
        #expect(
            ids(try run(s, LayerTree.reorderOps(s, id: "p1", forward: true))) == ["bg", "pools", "p2", "p1", "title"])
        #expect(LayerTree.reorderOps(s, id: "p2", forward: true).isEmpty)
        #expect(
            ids(try run(s, LayerTree.reorderOps(s, id: "title", forward: false))) == [
                "bg", "title", "pools", "p1", "p2",
            ])
    }

    @Test func groupAndUngroup() throws {
        let s = scene()
        let g = try run(s, LayerTree.groupOps(s, ids: ["bg", "title"], groupId: "group"))
        #expect(ids(g) == ["bg", "pools", "p1", "p2", "title", "group"])
        #expect(g.node("bg")?.parent == "group" && g.node("title")?.parent == "group" && g.node("group")?.parent == nil)
        // Grouping children of the same parent keeps the new group inside it.
        let g2 = try run(s, LayerTree.groupOps(s, ids: ["p1", "p2"], groupId: "inner"))
        #expect(g2.node("inner")?.parent == "pools" && g2.node("p1")?.parent == "inner")
        // A child with its group selected is not grouped separately.
        #expect(LayerTree.groupOps(s, ids: ["pools", "p1"], groupId: "x").last?["ids"] == ["pools"])

        // Ungroup: children move to the group's parent with its translation baked in.
        let u = try run(s, LayerTree.ungroupOps(s, groups: ["pools"]))
        #expect(u.node("pools") == nil && u.node("p1")?.parent == nil && u.node("p2")?.parent == nil)
        #expect(u.node("p1")?.props["x"] == .value(110) && u.node("p1")?.props["y"] == .value(50))
        guard case .keys(let ks)? = u.node("p2")?.props["x"] else { Issue.record("keys lost"); return }
        #expect(ks.map(\.v) == [100, 120])
        #expect(LayerTree.ungroupOps(s, groups: ["title"]).isEmpty)
    }

    @Test func summariesForPinnedRows() {
        var s = scene()
        #expect(LayerTree.cameraSummary(s) == "not set · 2D only")
        #expect(LayerTree.lookSummary(s) == "no grade")
        s.camera = .keys([Keyframe(t: 0, v: ["fov": 36, "position": [0, 0, 0]]), Keyframe(t: 2, v: ["fov": 36])])
        s.post = .value(["saturation": 0, "bloom": ["intensity": 0.5], "grain": 0.05])
        #expect(LayerTree.cameraSummary(s) == "fov 36 · moving")
        #expect(LayerTree.lookSummary(s) == "B&W · bloom · grain")
    }

    // MARK: Document-level

    @Test(.requiresMetal) func documentGroupUngroupUndoAndLock() throws {
        let (doc, project) = try makeDoc(scene: scene())
        defer { project.remove() }
        let order = LayerTree.visualOrder(doc.layerRows())
        doc.clickLayer("title", modifiers: [], order: order)
        doc.clickLayer("bg", modifiers: .command, order: order)
        #expect(doc.selectedIds == ["title", "bg"])
        doc.groupSelection()
        #expect(doc.selection == "group" && doc.scene.node("bg")?.parent == "group")
        doc.undo()
        #expect(doc.scene.node("group") == nil && doc.scene.node("bg")?.parent == nil)

        doc.clickLayer("pools", modifiers: [], order: order)
        doc.clickLayer("bg", modifiers: .shift, order: order)
        #expect(doc.selectedIds == ["pools", "p2", "p1", "bg"])
        doc.clickLayer("p2", modifiers: .command, order: order)
        #expect(doc.selectedIds == ["pools", "p1", "bg"])

        doc.selection = "pools"; doc.multiSelection = []
        doc.ungroupSelection()
        #expect(doc.scene.node("pools") == nil && doc.selectedIds == ["p1", "p2"])

        doc.setLocked(["title"], true)
        #expect(doc.isLocked("title") && !doc.isLocked("bg") && doc.isLocked("@camera"))
        doc.setLocked(["title"], false)
        #expect(doc.scene.node("title")?.props["_locked"] == nil)

        doc.rename("bg", "Background")
        #expect(doc.scene.node("bg")?.name == "Background")
        doc.rename("bg", "")
        #expect(doc.scene.node("bg")?.name == nil)
    }

    @Test(.requiresMetal) func lockIsInheritedFromGroups() throws {
        let (doc, project) = try makeDoc(scene: scene())
        defer { project.remove() }
        doc.setLocked(["pools"], true)
        #expect(doc.isLocked("p1") && !doc.isLockedDirect("p1"))
        doc.setLabel(["p1", "p2"], "blue")
        #expect(LayerLabel.name(doc.scene.node("p2")!) == "blue")
        doc.toggleSolo(["pools"])
        #expect(doc.isSoloVisible("p1") && !doc.isSoloVisible("title"))
    }
}
