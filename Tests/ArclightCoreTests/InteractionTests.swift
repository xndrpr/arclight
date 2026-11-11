import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightEditor

/// Click-vs-drag threshold, past-END rules, endless timeline panning and layer-list drop zones.
@Suite(.serialized) struct InteractionTests {
    typealias S = ArclightCore.Scene

    @Test func clickSlop() {
        #expect(!ClickSlop.isDrag(distance: 3, elapsed: 2))  // slow, tiny wobble: still a click
        #expect(!ClickSlop.isDrag(distance: 8, elapsed: 0.05))  // tap-to-click while the finger moves
        #expect(ClickSlop.isDrag(distance: 5, elapsed: 0.2))  // deliberate small drag
        #expect(ClickSlop.isDrag(distance: 13, elapsed: 0.01))  // fast flick
    }

    @Test func pressTracker() {
        let t0 = Date()
        var p = PressTracker()
        p.begin(now: t0)
        let jitter = p.update(CGSize(width: 6, height: 2), now: t0.addingTimeInterval(0.03))
        let tap = p.end()
        #expect(!jitter && tap)  // tap with jitter = click
        p.begin(now: t0)
        let d1 = p.update(CGSize(width: 6, height: 0), now: t0.addingTimeInterval(0.3))
        let d2 = p.update(.zero, now: t0.addingTimeInterval(0.4))  // latched: back at the start is still a drag
        let click = p.end()
        #expect(d1 && d2 && !click)
        let none = p.end()
        #expect(!none)  // no press: not a click
    }

    private func scene() -> S {
        var s = S(id: "s", duration: 5)
        s.nodes = [Node(id: "a", type: "shape", props: ["x": .keys([Keyframe(t: 0, v: 0), Keyframe(t: 2, v: 100)])])]
        return s
    }

    @Test func pastEndGrowsOnlyForNewContent() {
        let fps = 30.0
        #expect(abs(SceneExtent.lastFrame(5, fps: fps) - 149.0 / 30) < 1e-9)
        let before = scene()
        var after = before
        after.nodes[0].props["x"] = .keys([Keyframe(t: 0, v: 0), Keyframe(t: 7, v: 100)])
        let d = SceneExtent.grownDuration(before: before, after: after, fps: fps)
        #expect(d != nil && abs(d! - (7 + 1 / fps)) < 1e-9)
        #expect(SceneExtent.lastFrame(d!, fps: fps) >= 7 - 1e-9)  // the new key is on a rendered frame
        // A key exactly at END is fine.
        after.nodes[0].props["x"] = .keys([Keyframe(t: 0, v: 0), Keyframe(t: 5, v: 100)])
        #expect(SceneExtent.grownDuration(before: before, after: after, fps: fps) == nil)
        // A new layer starting past END gets a second.
        var add = before
        var n = Node(id: "b", type: "text"); n.start = 6
        add.nodes.append(n)
        #expect(SceneExtent.grownDuration(before: before, after: add, fps: fps) == 7)
        // Content already past END (older files, END dragged back on purpose) is left alone.
        var over = before; over.duration = 1
        var over2 = over; over2.nodes[0].props["y"] = .value(3)
        #expect(SceneExtent.grownDuration(before: over, after: over2, fps: fps) == nil)
    }

    @Test(.requiresMetal) func documentPastEnd() throws {
        EditorDocument.recordRecents = false
        let (doc, project) = try makeDoc(scene: scene())
        defer { project.remove() }
        doc.open(scene: "s")
        // Endless panning at a fixed scale.
        let v = doc.tlVisible
        for _ in 0..<2000 { doc.setTimelineOffset(doc.tlOffset + 1) }
        #expect(doc.tlOffset >= 2000 - 1e-9 && doc.tlVisible == v)
        doc.setTimelineOffset(-5)
        #expect(doc.tlOffset == 0)
        // Playhead past END: the viewer holds the last frame.
        doc.time = 9
        #expect(doc.isPastEnd && doc.viewTime == doc.lastFrameTime && doc.maxTime > 9)
        // Dragging END shorter never auto-grows back.
        doc.setDuration(1)
        #expect(doc.scene.duration == 1)
        doc.setDuration(5)
        // Auto-key past END extends the scene.
        doc.set("a", "x", .number(50))
        #expect(doc.scene.duration > 9)
        #expect(!doc.isPastEnd)
    }

    @Test func layerDropZones() {
        var s = S(id: "s")
        s.nodes = [
            Node(id: "bg", type: "shape"), Node(id: "g", type: "group"), Node(id: "c", type: "text", parent: "g"),
            Node(id: "top", type: "text"),
        ]
        let rows = LayerTree.rows(s, selection: nil)  // @camera, @look, top, g, c, bg
        let ids = rows.map(\.node.id)
        #expect(ids == ["@camera", "@look", "top", "g", "c", "bg"])
        let h: CGFloat = 20
        func z(_ y: CGFloat, _ drag: [String] = ["bg"]) -> LayerTree.Drop? {
            LayerTree.dropZone(s, rows: rows, y: y, rowH: h, collapsed: [], dragging: drag)
        }
        #expect(z(2 * h + 2) == .above("top"))
        #expect(z(2 * h + 15) == .below("top"))
        #expect(z(3 * h + 10) == .into("g"))  // middle of a group
        #expect(z(3 * h + 18) == .into("g"))  // bottom of an expanded group goes into it
        #expect(z(5) == .above("top"))  // over the pinned rows: top of the stack
        #expect(z(40 * h, ["top"]) == .below("bg"))  // below everything
        #expect(z(4 * h + 5, ["g"]) == nil)  // can't drop into its own child
        #expect(z(5 * h + 5) == nil)  // over itself
        #expect(LayerTree.dropZone(s, rows: rows, y: 50, rowH: h, collapsed: [], dragging: []) == nil)
    }
}
