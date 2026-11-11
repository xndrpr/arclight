import ArclightCore
import CoreGraphics
import Foundation

/// Where the selection box, handles, rotate handle and anchor crosshair are, in canvas-view points
/// (canvas px × scale). Built once per render from the evaluated layers.
struct GizmoLayout {
    /// Single layer: its oriented quad. Several: the axis-aligned union box. TL, TR, BR, BL.
    var box: [CGPoint]?
    /// Outlines of every selected 2D layer (when several are selected).
    var outlines: [[CGPoint]] = []
    /// The one transformable layer (single selection): enables rotate and anchor.
    var single: EvalNode?
    var pivot: CGPoint?
    var rotate: CGPoint?
    var multi: Bool { single == nil && box != nil }

    private static let handleHit: CGFloat = 7
    static let rotateOffset: CGFloat = 24

    static func make(_ doc: EditorDocument, nodes: [EvalNode], scale s: CGFloat) -> GizmoLayout {
        func view(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * s, y: p.y * s) }
        let movable = doc.movable2D(nodes)
        var L = GizmoLayout()
        if movable.count == 1, let n = movable.first, let q = doc.canvasQuad(n) {
            let vq = q.map(view)
            L.box = vq; L.single = n; L.pivot = view(doc.pivot(n))
            L.rotate = rotateHandle(vq)
        } else if movable.count > 1 {
            let quads = movable.compactMap { doc.canvasQuad($0)?.map(view) }
            L.outlines = quads
            let u = TransformMath.bounds(quads.flatMap { $0 })
            L.box = u.corners
        }
        return L
    }

    /// Rotate handle: above the top edge's midpoint, along the box's own "up".
    static func rotateHandle(_ q: [CGPoint]) -> CGPoint {
        let top = Handle.top.point(on: q), bottom = Handle.bottom.point(on: q)
        var d = CGPoint(x: top.x - bottom.x, y: top.y - bottom.y)
        let l = hypot(d.x, d.y)
        d = l > 0.5 ? CGPoint(x: d.x / l, y: d.y / l) : CGPoint(x: 0, y: -1)
        return CGPoint(x: top.x + d.x * rotateOffset, y: top.y + d.y * rotateOffset)
    }

    func handle(at p: CGPoint) -> Handle? {
        guard let q = box else { return nil }
        return Handle.allCases.first { hypot($0.point(on: q).x - p.x, $0.point(on: q).y - p.y) <= Self.handleHit }
    }

    func onRotate(_ p: CGPoint) -> Bool { rotate.map { hypot($0.x - p.x, $0.y - p.y) <= Self.handleHit + 1 } ?? false }
    func onPivot(_ p: CGPoint) -> Bool { pivot.map { hypot($0.x - p.x, $0.y - p.y) <= Self.handleHit } ?? false }
}
