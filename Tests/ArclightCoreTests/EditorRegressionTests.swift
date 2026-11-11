import AppKit
import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightEditor

// Regression tests for the editor bugs found in the 0.1.0 release work (B5, B6, B12, B15).

private func shape(_ id: String, x: Double, y: Double, w: Double = 100, h: Double = 50) -> Node {
    Node(
        id: id, type: "shape",
        props: [
            "shape": .value("rect"), "x": .value(.number(x)), "y": .value(.number(y)), "width": .value(.number(w)),
            "height": .value(.number(h)),
        ])
}

/// Two scenes, "a" and "b", in a fresh project; the document opens on "a".
private func twoSceneDoc() throws -> (doc: EditorDocument, project: TempProject) {
    var a = ArclightCore.Scene(id: "a", duration: 4)
    a.nodes = [shape("r", x: 400, y: 300)]
    var b = ArclightCore.Scene(id: "b", duration: 4)
    b.nodes = [shape("s", x: 500, y: 300)]
    let p = try TempProject("ki-editor", scenes: [a, b])
    let doc = try EditorDocument(url: p.url)
    if doc.scene.id != "a" { doc.open(scene: "a") }
    return (doc, p)
}

@Suite(.serialized) struct EditorRegressionTests {
    // MARK: B5

    /// B5: deleting the open scene must drop its undo history, so ⌘Z cannot bring the deleted scene back.
    @Test(.requiresMetal) func b5_deleteOpenSceneDropsItsUndoStack() throws {
        let (doc, p) = try twoSceneDoc()
        defer { p.remove() }
        doc.edit { $0.name = "renamed" }
        #expect(!doc.undoStack.isEmpty)  // setup: there is history to leak
        doc.deleteScene("a")
        #expect(doc.scene.id == "b")  // setup: the other scene was opened
        let undoDepth = doc.undoStack.count
        doc.undo()
        doc.saveNow()
        let onDisk = try ProjectStore(url: p.url)
        #expect(doc.scene.id == "b")
        #expect(onDisk.scenes["a"] == nil)
        #expect(undoDepth == 0)
    }

    /// B5: deleting the open scene resets the playhead and per-scene state the way opening a scene does.
    @Test(.requiresMetal) func b5_deleteOpenSceneResetsSceneState() throws {
        let (doc, p) = try twoSceneDoc()
        defer { p.remove() }
        doc.edit { $0.name = "renamed" }
        doc.undo()  // leaves a redo step
        doc.time = 2
        doc.playing = true
        doc.selection = "r"
        doc.multiSelection = ["r"]
        doc.soloIds = ["r"]
        doc.workArea = 1...2
        doc.deleteScene("a")
        #expect(doc.scene.id == "b")
        #expect(doc.undoStack.isEmpty)
        #expect(doc.redoStack.isEmpty)
        #expect(doc.time == 0)
        #expect(!doc.playing)
        #expect(doc.selection == nil)
        #expect(doc.multiSelection.isEmpty)
        #expect(doc.soloIds.isEmpty)
        #expect(doc.workArea == nil)
    }

    /// B5: the open scene deleted on disk (an AI's `scene_delete`): live reload switches scenes without the old
    /// history, so ⌘Z + save cannot re-create it.
    @Test(.requiresMetal) func b5_openSceneDeletedOnDiskDropsItsHistory() throws {
        let (doc, p) = try twoSceneDoc()
        defer { p.remove() }
        doc.edit { $0.name = "renamed" }
        doc.saveNow()
        try ProjectStore(url: p.url).deleteScene("a")
        doc.poll()
        #expect(doc.scene.id == "b")
        #expect(doc.undoStack.isEmpty)
        doc.undo()
        doc.saveNow()
        #expect(try ProjectStore(url: p.url).scenes["a"] == nil)
    }

    /// B5: opening another scene clears the multi-selection, solo, work area and flash highlights of the old one.
    @Test(.requiresMetal) func b5_openSceneResetsPerSceneState() throws {
        let (doc, p) = try twoSceneDoc()
        defer { p.remove() }
        doc.multiSelection = ["r"]
        doc.soloIds = ["r"]
        doc.workArea = 1...2
        doc.flashIds = ["r"]
        doc.open(scene: "b")
        #expect(doc.scene.id == "b")  // setup
        #expect(doc.multiSelection.isEmpty)
        #expect(doc.soloIds.isEmpty)
        #expect(doc.workArea == nil)
        #expect(doc.flashIds.isEmpty)
    }

    // MARK: B6

    /// B6: the theme undo history and library version used to live in ObjectIdentifier-keyed side tables that were
    /// never pruned, so a new document allocated at a freed document's address inherited them. They are stored on
    /// the document now. This checks the visible effect (address reuse is up to the allocator; when the loop finds
    /// no reused address the run proves nothing either way, but the expectation still holds).
    @Test(.requiresMetal) func b6_sideTablesGoWithTheirDocument() throws {
        var a = ArclightCore.Scene(id: "a", duration: 4)
        a.nodes = [shape("r", x: 400, y: 300)]
        let p = try TempProject("ki-b6", scenes: [a])
        defer { p.remove() }
        var firstId: ObjectIdentifier?
        do {
            let doc = try EditorDocument(url: p.url)
            firstId = ObjectIdentifier(doc)
            doc.libraryVersion = 7
            doc.setThemeToken("b6", .string("#ff0000"))
            #expect(doc.libraryVersion == 7)  // setup
            #expect(doc.canUndoTheme)  // setup
        }
        var inherited = false
        for _ in 0..<40 {
            let fresh = try EditorDocument(url: p.url)
            #expect(!fresh.canUndoTheme)
            if ObjectIdentifier(fresh) == firstId { inherited = fresh.libraryVersion != 0 || fresh.canUndoTheme }
            // keep it alive no longer than the iteration: the next one may reuse the address
        }
        #expect(!inherited)
    }

    // MARK: B12

    /// B12: zooming in from a Fit scale above the maximum must not shrink the view.
    @Test func b12_zoomInFromAFitAboveTheMaximumDoesNotShrink() {
        let vp = ViewportState()
        vp.viewSize = CGSize(width: 1000, height: 800); vp.canvas = CGSize(width: 50, height: 50); vp.pad = 24
        let fit = vp.fitScale
        #expect(fit > ViewZoom.maxScale)  // setup: Fit is above 8x
        vp.zoom(by: 1.25, at: nil)
        #expect(vp.scale >= fit)
        vp.zoom(by: 0.8, at: nil)  // zooming out from there still works
        #expect(vp.scale < fit)
        #expect(ViewZoom.clamp(100) == ViewZoom.maxScale)  // ordinary limits are unchanged
        #expect(ViewZoom.clamp(0.001, fit: 0.5) == ViewZoom.minScale)
    }

    /// B12: zooming out from a Fit scale below the minimum must not enlarge the view.
    @Test func b12_zoomOutFromAFitBelowTheMinimumDoesNotGrow() {
        let vp = ViewportState()
        vp.viewSize = CGSize(width: 1000, height: 800); vp.canvas = CGSize(width: 100_000, height: 100_000)
        vp.pad = 24
        let fit = vp.fitScale
        #expect(fit < ViewZoom.minScale)  // setup: Fit is below 5 %
        vp.zoom(by: 0.8, at: nil)
        #expect(vp.scale <= fit)
        vp.zoom(by: 2, at: nil)  // zooming in from there still works
        #expect(vp.scale > fit)
    }

    // MARK: B15f

    /// B15f: `fmt` prints tiny values as "0", not "0.".
    @Test func b15f_fmtTinyValuesHaveNoTrailingDot() {
        #expect(fmt(0.5) == "0.5")
        #expect(fmt(2) == "2")
        #expect(fmt(0.0004) == "0")
        #expect(fmt(-0.0004) == "0")
        #expect(fmt(2.0004) == "2")
        #expect(fmt(100.0002) == "100")
        #expect(fmt(1.05) == "1.05")
        #expect(fmt(-1.5) == "-1.5")
        #expect(fmt(10.25) == "10.25")
    }

    // MARK: B15h

    /// B15h: the canvas drag snaps only while Settings > snapping (`ui.snapping`) is on; `canvas.snap` follows it.
    @Test(.requiresMetal) @MainActor func b15h_canvasSnapFollowsUiSnapping() throws {
        _ = NSApplication.shared  // `begin` calls endEditing(), which needs NSApp (no window is created)
        let d = Pref.store
        let keys = [Pref.snapping, Pref.canvasSnap]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }
        for k in keys { d.removeObject(forKey: k) }

        var s = ArclightCore.Scene(id: "a", duration: 4)
        s.nodes = [shape("r", x: 900, y: 300)]

        /// Drags the layer 62 px right (its centre lands 2 px from the canvas centre line) and returns the snap lines.
        func dragLines(snapping: Bool) throws -> [SnapLine] {
            let p = try TempProject("ki-b15h", scenes: [s])  // a drag saves, so each run gets a fresh project
            defer { p.remove() }
            d.set(snapping, forKey: Pref.snapping)
            let doc = try EditorDocument(url: p.url)
            doc.snapping = snapping
            doc.selection = "r"
            let vp = ViewportState()
            vp.viewSize = doc.canvasSize; vp.canvas = doc.canvasSize
            vp.setScale(1)
            let nodes = doc.evaluate()
            let layout = GizmoLayout.make(doc, nodes: nodes, scale: 1)
            let node = try #require(nodes.first { $0.node.id == "r" })
            let r = try #require(doc.canvasRect(node))
            let start = CGPoint(x: r.midX + 20, y: r.midY + 10)  // inside the layer, away from the pivot
            let session = GizmoSession()
            session.begin(at: start, doc: doc, vp: vp, nodes: nodes, layout: layout)
            #expect(session.mode == .move)
            session.drag(
                to: CGPoint(x: start.x + 62, y: start.y), translation: CGSize(width: 62, height: 0), doc: doc, vp: vp)
            let lines = session.snapLines
            session.end(doc: doc)
            return lines
        }
        #expect(!(try dragLines(snapping: true)).isEmpty)  // setup: snapping on does snap
        let off = try dragLines(snapping: false)
        #expect(off.isEmpty)
    }

    /// B15h: an old `canvas.snap` is read once: it becomes `ui.snapping` when that was never set, and is removed.
    @Test func b15h_oldCanvasSnapIsReadOnce() {
        let d = Pref.store
        let keys = [Pref.snapping, Pref.canvasSnap]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { if let v { d.set(v, forKey: k) } else { d.removeObject(forKey: k) } } }

        for k in keys { d.removeObject(forKey: k) }
        #expect(Pref.storedSnapping(d))  // default on

        d.set(false, forKey: Pref.canvasSnap)  // canvas snapping was turned off, Settings never touched
        #expect(!Pref.storedSnapping(d))
        #expect(d.object(forKey: Pref.canvasSnap) == nil)
        #expect(d.object(forKey: Pref.snapping) as? Bool == false)

        d.set(true, forKey: Pref.snapping)  // an explicit ui.snapping wins over an old canvas.snap
        d.set(false, forKey: Pref.canvasSnap)
        #expect(Pref.storedSnapping(d))
        #expect(d.object(forKey: Pref.canvasSnap) == nil)
    }
}
