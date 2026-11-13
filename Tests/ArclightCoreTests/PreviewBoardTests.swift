import CoreGraphics
import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightEditor

/// Phase 2: the board (artboards around the open one), drawing tools, arrange, and board zoom / pan maths.
@Suite(.serialized, .requiresMetal) struct PreviewBoardTests {
    private func doc() throws -> (EditorDocument, TempProject) {
        let tp = try TempProject("pv-board")
        var a = Artboard(id: "a", name: "A")
        a.nodes = [
            Node(id: "one", type: "shape", props: ["shape": .value("rect")]),
            Node(id: "two", type: "shape", props: ["shape": .value("rect")]),
            Node(id: "three", type: "shape", props: ["shape": .value("rect")]),
        ]
        var b = Artboard(id: "b", name: "B", x: 1400, y: 0)
        b.size = [1080, 1920]
        try tp.store.save(preview: ArclightCore.Preview(id: "p", artboards: [a, b]))
        return (try EditorDocument(url: tp.url), tp)
    }

    @Test func boardRectsAreRelativeToTheOpenArtboard() throws {
        let (d, tp) = try doc()
        defer { tp.remove() }
        #expect(d.boardRects().map(\.rect) == [CGRect(x: 0, y: 0, width: 1280, height: 720), CGRect(x: 1400, y: 0, width: 1080, height: 1920)])
        d.open(preview: "p", artboard: "b")
        #expect(d.boardRects().first?.rect.minX == -1400)
        d.moveArtboard("a", by: CGSize(width: -100, height: 50))
        #expect(d.openPreview?.artboard("a")?.x == -100 && d.openPreview?.artboard("a")?.y == 50)
        #expect(d.target == .artboard(preview: "p", artboard: "b"))  // still editing B
    }

    @Test func drawingToolsCreateLayersFromDrags() throws {
        let (d, tp) = try doc()
        defer { tp.remove() }
        d.tool = .rect
        d.createLayer(with: .rect, from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 200))
        let r = try #require(d.scene.node(d.selection ?? ""))
        #expect(r.props["x"] == .value(200) && r.props["y"] == .value(150))  // rects are centred on x,y
        #expect(r.props["width"] == .value(200) && r.props["height"] == .value(100))
        #expect(d.tool == .move)  // back to Move after drawing (Figma)
        d.createLayer(with: .ellipse, from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 40), square: true)
        let e = try #require(d.scene.node(d.selection ?? ""))
        #expect(e.props["width"] == e.props["height"])
        d.createLayer(with: .line, from: CGPoint(x: 10, y: 10), to: CGPoint(x: 110, y: 60))
        #expect(d.scene.node(d.selection ?? "")?.props["to"] == .value([100, 50]))
        d.createLayer(with: .text, from: CGPoint(x: 40, y: 50), to: CGPoint(x: 40, y: 50))
        let t = try #require(d.scene.node(d.selection ?? ""))
        #expect(t.type == "text" && t.props["x"] == .value(40))
        #expect(Validator.validate(d.scene).isEmpty, "\(Validator.validate(d.scene))")
    }

    @Test func arrangeToFrontAndBack() throws {
        let (d, tp) = try doc()
        defer { tp.remove() }
        d.selection = "one"
        d.arrange(toFront: true)
        #expect(d.scene.nodes.map(\.id) == ["two", "three", "one"])
        d.selection = "three"
        d.arrange(toFront: false)
        #expect(d.scene.nodes.map(\.id) == ["three", "two", "one"])
    }

    @Test func boardPanClampKeepsTheBoardReachable() {
        let view = CGSize(width: 1000, height: 600), canvas = CGSize(width: 1280, height: 720)
        let board = CGRect(x: 0, y: 0, width: 2480, height: 1920)
        // Far to the left (looking at the second artboard) is allowed on a board…
        let p = ViewZoom.clampPan(CGSize(width: -900, height: 0), board: board, canvas: canvas, scale: 0.5, view: view)
        #expect(p.width == -900)
        // …but not so far that the whole board leaves the view.
        let q = ViewZoom.clampPan(CGSize(width: -5000, height: 0), board: board, canvas: canvas, scale: 0.5, view: view)
        #expect(q.width > -5000)
        let vp = ViewportState()
        vp.viewSize = view; vp.canvas = canvas; vp.pad = 24; vp.board = board
        vp.fitBoard()
        // The board's centre lands in the middle of the view.
        let s = vp.scale
        #expect(abs(vp.pan.width - (canvas.width / 2 - board.midX) * s) < 0.01)
        #expect(s < vp.fitScale)
    }

    @Test func tilesRenderInWidthBuckets() {
        #expect(BoardTile.bucket(300, max: 1280) == 512)
        #expect(BoardTile.bucket(3000, max: 1280) == 1280)
        #expect(BoardTile.bucket(100, max: 1280) == 256)
    }

    @Test func previewOnlyShowsArtboardKeysInTheShortcutSheet() {
        let all = (Shortcuts.previewLeft + Shortcuts.previewRight).flatMap { $0.items.map(\.action) }
        #expect(all.contains { $0.contains("Zoom to fit all artboards") })
        #expect(!all.contains { $0.contains("Shuttle") })
    }
}
