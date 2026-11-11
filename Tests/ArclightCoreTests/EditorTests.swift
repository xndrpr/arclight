import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightEditor

@Suite(.serialized, .requiresMetal) struct EditorDocumentTests {
    /// One scene "s" with a text layer "title" (constant x, animated opacity).
    static var scene: ArclightCore.Scene {
        var s = ArclightCore.Scene(id: "s", duration: 4)
        s.nodes = [
            Node(
                id: "title", type: "text",
                props: [
                    "text": .value("Hi"), "x": .value(10),
                    "opacity": .keys([Keyframe(t: 0, v: 0), Keyframe(t: 1, v: 1)]),
                ])
        ]
        return s
    }

    @Test func editUndoRedoAndSave() throws {
        let (doc, project) = try makeDoc(scene: Self.scene)
        defer { project.remove() }
        let rev0 = doc.scene.rev

        doc.set("title", "x", 200)  // constant → set
        #expect(doc.scene.node("title")?.props["x"] == .value(200))
        doc.time = 2
        doc.set("title", "opacity", 0.5)  // animated → auto-key at t=2
        guard case .keys(let ks)? = doc.scene.node("title")?.props["opacity"] else { Issue.record("not keyed"); return }
        #expect(ks.map(\.t) == [0, 1, 2] && ks[2].v == .number(0.5))

        doc.undo()
        #expect(doc.scene.node("title")?.props["opacity"]?.keyCount == 2)
        doc.redo()
        #expect(doc.scene.node("title")?.props["opacity"]?.keyCount == 3)

        doc.saveNow()
        let disk = try ProjectStore(url: project.url).scene("s")
        #expect(disk.rev == rev0 + 1 && disk.node("title")?.props["x"] == .value(200))
    }

    @Test func gestureCoalescesIntoOneUndo() throws {
        let (doc, project) = try makeDoc(scene: Self.scene)
        defer { project.remove() }
        doc.beginGesture()
        for x in stride(from: 10.0, through: 100, by: 10) { doc.set("title", "x", .number(x)) }
        doc.endGesture()
        #expect(doc.scene.node("title")?.props["x"] == .value(100))
        doc.undo()
        #expect(doc.scene.node("title")?.props["x"] == .value(10))
        #expect(!doc.canUndo)
    }

    @Test func liveReloadPicksUpExternalWrites() throws {
        let (doc, project) = try makeDoc(scene: Self.scene)
        defer { project.remove() }
        // Simulate an AI agent editing through MCP (separate store, same files).
        let other = try ProjectStore(url: project.url)
        var s = try other.scene("s")
        s.nodes[0].props["text"] = .value("From the agent")
        Thread.sleep(forTimeInterval: 1.1)  // file mtime resolution
        try other.save(scene: s, summary: "mcp")
        doc.poll()
        #expect(doc.scene.node("title")?.props["text"] == .value("From the agent"))
        doc.undo()  // the user's previous state is still reachable
        #expect(doc.scene.node("title")?.props["text"] == .value("Hi"))
    }

    @Test func addDuplicateDeleteLayers() throws {
        let (doc, project) = try makeDoc(scene: Self.scene)
        defer { project.remove() }
        doc.addNode("shape", props: ["shape": "ellipse", "width": 100])
        #expect(doc.selection == "ellipse" && doc.scene.node("ellipse") != nil)
        doc.duplicateSelection()
        #expect(doc.selection == "ellipse-2" && doc.scene.nodes.map(\.id) == ["title", "ellipse", "ellipse-2"])
        doc.deleteSelection()
        #expect(doc.scene.node("ellipse-2") == nil && doc.selection == nil)
        #expect(Validator.validate(doc.scene).isEmpty)
    }

    @Test func keyframeNavigationResetAndInOut() throws {
        let (doc, project) = try makeDoc(scene: Self.scene)
        defer { project.remove() }
        doc.selection = "title"
        doc.time = 0.5
        doc.jumpKey(forward: true, node: "title", prop: "opacity")
        #expect(doc.time == 1)
        doc.jumpKey(forward: false, node: "title", prop: "opacity")
        #expect(doc.time == 0)
        doc.time = 0.5
        doc.clearAnimation("title", "opacity")
        #expect(doc.scene.node("title")?.props["opacity"] == .value(0.5))
        doc.time = 1
        doc.setInOut(isIn: true)
        doc.time = 3
        doc.setInOut(isIn: false)
        #expect(doc.scene.node("title")?.start == 1 && doc.scene.node("title")?.end == 3)
        doc.clearInOut()
        #expect(doc.scene.node("title")?.start == nil)
    }

    @Test func shuttleZoomSnapCopyPasteRename() throws {
        let (doc, project) = try makeDoc(scene: Self.scene)
        defer { project.remove() }
        doc.shuttle(1); doc.shuttle(1); doc.shuttle(1)
        #expect(doc.playing && doc.rate == 4)
        doc.shuttle(-1)
        #expect(doc.rate == -1)
        doc.shuttle(0)
        #expect(!doc.playing)

        doc.time = 2
        let fit = doc.tlVisible
        #expect(fit > doc.scene.duration)  // room after the end
        doc.zoomTimeline(by: 4, anchor: 2)
        let v = doc.tlVisible
        #expect(abs(v - fit / 4) < 1e-9 && doc.tlOffset <= 2 && doc.tlOffset + v >= 2)
        // Regression: scrolling past the end must never change the scale (it used to collapse to a white bar).
        for _ in 0..<500 { doc.setTimelineOffset(doc.tlOffset + 0.5) }
        #expect(doc.tlVisible == v && doc.tlOffset + v <= doc.panLimit + 1e-9 && doc.maxTime > doc.scene.duration)
        doc.setDuration(10)  // a longer scene doesn't rescale the view
        #expect(doc.scene.duration == 10 && doc.tlVisible == v)
        doc.zoomToFit(animated: false)
        #expect(abs(doc.tlZoom - 1) < 1e-9 && doc.tlOffset == 0 && doc.tlVisible >= 12)
        doc.zoomTimeline(by: 1 / 1000)  // zoom-out is bounded too
        #expect(doc.tlVisible <= doc.panLimit + 1e-9)

        doc.time = 2
        #expect(doc.snapTime(1.03, tolerance: 0.1) == 1)  // snaps to the opacity key at t=1
        doc.snapping = false
        #expect(abs(doc.snapTime(1.03, tolerance: 0.1) - 31.0 / 30) < 1e-9)  // frame only

        doc.selection = "title"
        doc.copySelection()
        doc.paste()
        #expect(doc.selection == "title-2" && doc.scene.nodes.count == 2)

        doc.renameProject("Renamed")
        #expect(try ProjectStore(url: project.url).project.name == "Renamed")

        doc.setProjectCanvas(width: 1080, height: 1920)
        doc.setProjectFPS(60)
        #expect(doc.canvasSize == CGSize(width: 1080, height: 1920) && doc.fps == 60)
        doc.setSceneCanvas([1080, 1080])
        #expect(doc.canvasSize == CGSize(width: 1080, height: 1080))
        doc.renameScene("s", "Intro")
        #expect(doc.scene.name == "Intro")
    }

    @Test func timelineRowsAndBounds() throws {
        let (doc, project) = try makeDoc(scene: Self.scene)
        defer { project.remove() }
        doc.selection = "title"
        let rows = LayerTree.rows(doc.scene, selection: "title", pinned: false)
        #expect(rows.map(\.id) == ["title", "title.opacity"])
        #expect(TL.keyTimes(rows[1]) == [0, 1])
        doc.time = 1
        let n = doc.evaluate().first { $0.node.id == "title" }!
        let b = doc.renderer.localBounds(n)!
        #expect(b.width > 50 && b.height > 50)
    }
}
