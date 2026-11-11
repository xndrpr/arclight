import ArclightCore
import CoreGraphics
import Foundation

// Pure transform math: handles, scale/rotate drags, anchor compensation, align/distribute.

// MARK: Transform handles

/// The 8 box handles, clockwise from top-left. `dir` is the handle's side in box space (−1, 0, +1).
enum Handle: Int, CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var dir: (x: CGFloat, y: CGFloat) {
        switch self {
        case .topLeft: return (-1, -1)
        case .top: return (0, -1)
        case .topRight: return (1, -1)
        case .right: return (1, 0)
        case .bottomRight: return (1, 1)
        case .bottom: return (0, 1)
        case .bottomLeft: return (-1, 1)
        case .left: return (-1, 0)
        }
    }
    var isCorner: Bool { dir.x != 0 && dir.y != 0 }
    var opposite: Handle { Handle(rawValue: (rawValue + 4) % 8)! }

    /// Handle position on a quad given as TL, TR, BR, BL.
    func point(on q: [CGPoint]) -> CGPoint {
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        switch self {
        case .topLeft: return q[0]
        case .top: return mid(q[0], q[1])
        case .topRight: return q[1]
        case .right: return mid(q[1], q[2])
        case .bottomRight: return q[2]
        case .bottom: return mid(q[2], q[3])
        case .bottomLeft: return q[3]
        case .left: return mid(q[3], q[0])
        }
    }
}

extension CGRect {
    /// Corners clockwise from top-left: TL, TR, BR, BL.
    var corners: [CGPoint] {
        [CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY), CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY)]
    }
}

enum TransformMath {
    /// Scale factors from dragging a handle: `v0`/`v` are the grab point and the pointer relative to the scale
    /// origin, in the layer's unscaled (rotated) frame. Sides change one axis; corners both (`uniform` = equal).
    static func scaleFactors(handle: Handle, v0: CGPoint, v: CGPoint, uniform: Bool) -> (x: CGFloat, y: CGFloat) {
        func ratio(_ a: CGFloat, _ b: CGFloat) -> CGFloat { abs(a) < 0.5 ? 1 : b / a }
        let d = handle.dir
        var fx = d.x != 0 ? ratio(v0.x, v.x) : 1, fy = d.y != 0 ? ratio(v0.y, v.y) : 1
        if uniform {
            if handle.isCorner {
                let l0 = hypot(v0.x, v0.y)
                let f = l0 < 0.5 ? 1 : (v.x * v0.x + v.y * v0.y) / (l0 * l0)  // projection onto the diagonal
                fx = f; fy = f
            } else if d.x != 0 {
                fy = fx
            } else {
                fx = fy
            }
        }
        return (fx, fy)
    }

    /// Rotation (degrees) after dragging the rotate handle around `pivot` from `p0` to `p`; `snap` rounds to 15°.
    static func rotation(start: Double, pivot: CGPoint, from p0: CGPoint, to p: CGPoint, snap: Bool) -> Double {
        let a0 = atan2(p0.y - pivot.y, p0.x - pivot.x), a1 = atan2(p.y - pivot.y, p.x - pivot.x)
        var d = Double(a1 - a0) * 180 / .pi
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        let r = start + d
        return snap ? (r / 15).rounded() * 15 : (r * 10).rounded() / 10
    }

    /// New x/y so the layer doesn't move when its anchor changes `a0` → `a1` (layer px), given its
    /// rotation (degrees) and scale: (x, y) + R·S·(a1 − a0).
    static func compensate(
        x: Double, y: Double, rotation: Double, scale: (Double, Double),
        anchor a0: CGPoint, to a1: CGPoint
    ) -> (x: Double, y: Double) {
        let r = rotation * .pi / 180
        let dx = Double(a1.x - a0.x) * scale.0, dy = Double(a1.y - a0.y) * scale.1
        return (x + dx * cos(r) - dy * sin(r), y + dx * sin(r) + dy * cos(r))
    }

    /// Axis-aligned bounds of points.
    static func bounds(_ pts: [CGPoint]) -> CGRect {
        guard let f = pts.first else { return .null }
        var r = CGRect(origin: f, size: .zero)
        for p in pts.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }

    static func scaleParts(_ v: JSONValue?) -> (Double, Double) {
        if let a = v?.doubles, a.count >= 2 { return (a[0], a[1]) }
        let s = v?.double ?? 1
        return (s, s)
    }

    /// Scale as stored: a number when uniform (and it was a number), else [sx, sy]. Rounded to 0.001.
    static func scaleValue(_ sx: Double, _ sy: Double, wasArray: Bool) -> JSONValue {
        func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 }
        if !wasArray && abs(sx - sy) < 1e-9 { return .number(r(sx)) }
        return [.number(r(sx)), .number(r(sy))]
    }
}

// MARK: Align & distribute

enum AlignMode: String, CaseIterable {
    case left, hCenter, right, top, vMiddle, bottom, distributeH, distributeV

    var symbol: String {
        switch self {
        case .left: return "align.horizontal.left"
        case .hCenter: return "align.horizontal.center"
        case .right: return "align.horizontal.right"
        case .top: return "align.vertical.top"
        case .vMiddle: return "align.vertical.center"
        case .bottom: return "align.vertical.bottom"
        case .distributeH: return "distribute.horizontal.center"
        case .distributeV: return "distribute.vertical.center"
        }
    }
    var title: String {
        switch self {
        case .left: return "Align left"
        case .hCenter: return "Align centres horizontally"
        case .right: return "Align right"
        case .top: return "Align top"
        case .vMiddle: return "Align middles vertically"
        case .bottom: return "Align bottom"
        case .distributeH: return "Distribute horizontally (equal gaps)"
        case .distributeV: return "Distribute vertically (equal gaps)"
        }
    }
    var isDistribute: Bool { self == .distributeH || self == .distributeV }
}

enum Align {
    /// Canvas-space offsets per rect. Aligns to `bounds` when given (single layer → canvas), else to the
    /// rects' union. Distribute keeps the outermost rects and spaces the others with equal gaps.
    static func offsets(_ rects: [CGRect], _ mode: AlignMode, to bounds: CGRect? = nil) -> [CGSize] {
        guard !rects.isEmpty else { return [] }
        let u = bounds ?? rects.dropFirst().reduce(rects[0]) { $0.union($1) }
        switch mode {
        case .left: return rects.map { CGSize(width: u.minX - $0.minX, height: 0) }
        case .hCenter: return rects.map { CGSize(width: u.midX - $0.midX, height: 0) }
        case .right: return rects.map { CGSize(width: u.maxX - $0.maxX, height: 0) }
        case .top: return rects.map { CGSize(width: 0, height: u.minY - $0.minY) }
        case .vMiddle: return rects.map { CGSize(width: 0, height: u.midY - $0.midY) }
        case .bottom: return rects.map { CGSize(width: 0, height: u.maxY - $0.maxY) }
        case .distributeH, .distributeV:
            let h = mode == .distributeH
            var out = Array(repeating: CGSize.zero, count: rects.count)
            guard rects.count >= 3 else { return out }
            let order = rects.indices.sorted { h ? rects[$0].midX < rects[$1].midX : rects[$0].midY < rects[$1].midY }
            let first = rects[order.first!], last = rects[order.last!]
            let total = order.reduce(CGFloat(0)) { $0 + (h ? rects[$1].width : rects[$1].height) }
            let span = h ? last.maxX - first.minX : last.maxY - first.minY
            let gap = (span - total) / CGFloat(rects.count - 1)
            var pos = h ? first.minX : first.minY
            for i in order {
                let r = rects[i]
                let d = pos - (h ? r.minX : r.minY)
                out[i] = h ? CGSize(width: d, height: 0) : CGSize(width: 0, height: d)
                pos += (h ? r.width : r.height) + gap
            }
            return out
        }
    }
}
