import CoreGraphics
import Foundation

/// Built-in "chess" symbol pack: pieces built from simple geometric shapes.
/// Units are fractions of the full height (h = 1); origin at the centre of the base.
enum ChessPieces {
    static let names = ["pawn", "rook", "knight", "bishop", "queen", "king"]

    /// Builder that accepts the original canvas convention (y down, "up" is negative y)
    /// and emits y-up CoreGraphics paths.
    private final class B {
        var fills: [CGPath] = []
        let rim = CGMutablePath()
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: -y) }

        func trap(_ y0: Double, _ w0: Double, _ y1: Double, _ w1: Double) {
            poly([(-w0 / 2, y0), (w0 / 2, y0), (w1 / 2, y1), (-w1 / 2, y1)])
        }
        func rect(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) {
            poly([(x0, y0), (x1, y0), (x1, y1), (x0, y1)])
        }
        func poly(_ pts: [(Double, Double)]) {
            let g = CGMutablePath()
            g.addLines(between: pts.map { p($0.0, $0.1) }); g.closeSubpath()
            fills.append(g)
        }
        func circle(_ cx: Double, _ cy: Double, _ r: Double) {
            let g = CGMutablePath()
            g.addEllipse(in: CGRect(x: cx - r, y: -cy - r, width: r * 2, height: r * 2))
            fills.append(g)
        }
        func base(_ w: Double = 0.62) { trap(0, w, -0.055, w); trap(-0.05, w - 0.1, -0.12, w - 0.16) }

        // Rim helpers
        func line(_ y: Double, _ w: Double) { rim.move(to: p(-w / 2, y)); rim.addLine(to: p(w / 2, y)) }
        func seg(_ pts: [(Double, Double)]) {
            rim.move(to: p(pts[0].0, pts[0].1)); for q in pts.dropFirst() { rim.addLine(to: p(q.0, q.1)) }
        }
        /// Arc in canvas angles (y down), sampled as a polyline so direction is unambiguous.
        func arc(_ cy: Double, _ r: Double, _ a0: Double, _ a1: Double) {
            let n = 24
            seg(
                (0...n).map { k in
                    let a = a0 + (a1 - a0) * Double(k) / Double(n); return (r * cos(a), cy + r * sin(a))
                })
        }
    }

    static func make(_ type: String) -> VectorSprite? {
        let b = B()
        switch type {
        case "rook":
            b.trap(0, 0.66, -0.055, 0.66); b.trap(-0.05, 0.56, -0.12, 0.50); b.trap(-0.115, 0.42, -0.69, 0.34)
            b.trap(-0.685, 0.46, -0.74, 0.46); b.trap(-0.735, 0.40, -0.88, 0.50)
            b.rect(-0.25, -0.875, -0.12, -1); b.rect(-0.065, -0.875, 0.065, -1); b.rect(0.12, -0.875, 0.25, -1)
            for (x0, x1) in [(-0.25, -0.12), (-0.065, 0.065), (0.12, 0.25)] { b.seg([(x0, -1), (x1, -1)]) }
            b.line(-0.74, 0.46)
        case "pawn":
            b.base(0.60); b.trap(-0.115, 0.34, -0.56, 0.13); b.trap(-0.545, 0.32, -0.60, 0.32); b.circle(0, -0.75, 0.16)
            b.arc(-0.75, 0.15, .pi * 1.15, .pi * 1.85); b.line(-0.60, 0.32)
        case "bishop":
            b.base(0.60); b.trap(-0.115, 0.32, -0.56, 0.12); b.trap(-0.545, 0.30, -0.60, 0.30)
            let mitre = CGMutablePath()
            mitre.move(to: b.p(0, -0.59))
            mitre.addCurve(to: b.p(0, -0.93), control1: b.p(0.2, -0.62), control2: b.p(0.17, -0.82))
            mitre.addCurve(to: b.p(0, -0.59), control1: b.p(-0.17, -0.82), control2: b.p(-0.2, -0.62))
            mitre.closeSubpath()
            b.fills.append(mitre)
            b.circle(0, -0.965, 0.045)
            b.rim.move(to: b.p(-0.1, -0.84)); b.rim.addQuadCurve(to: b.p(0.1, -0.84), control: b.p(0, -0.95))
            b.line(-0.60, 0.30)
        case "knight":
            b.base(0.62)
            b.poly([
                (0.23, -0.11), (0.27, -0.4), (0.25, -0.62), (0.19, -0.8), (0.1, -0.92), (0.03, -0.95), (-0.01, -1.0),
                (-0.06, -0.91),
                (-0.15, -0.86), (-0.3, -0.71), (-0.35, -0.62), (-0.31, -0.56), (-0.2, -0.57), (-0.08, -0.52),
                (-0.19, -0.36), (-0.24, -0.11),
            ])
            b.seg([(-0.3, -0.71), (-0.15, -0.86), (-0.06, -0.91), (-0.01, -1.0), (0.03, -0.95), (0.1, -0.92)])
        case "queen":
            b.base(0.64); b.trap(-0.115, 0.34, -0.6, 0.14); b.trap(-0.585, 0.32, -0.64, 0.32)
            b.poly([
                (-0.11, -0.63), (0.11, -0.63), (0.19, -0.84), (0.13, -0.79), (0.09, -0.9), (0.04, -0.8), (0, -0.92),
                (-0.04, -0.8),
                (-0.09, -0.9), (-0.13, -0.79), (-0.19, -0.84),
            ])
            b.circle(0, -0.965, 0.045)
            b.arc(-0.965, 0.04, .pi * 1.15, .pi * 1.85); b.line(-0.64, 0.32)
        case "king":
            b.base(0.64); b.trap(-0.115, 0.34, -0.6, 0.15); b.trap(-0.585, 0.33, -0.64, 0.33)
            b.trap(-0.635, 0.2, -0.84, 0.3); b.trap(-0.835, 0.3, -0.865, 0.3)
            b.rect(-0.025, -0.86, 0.025, -1.0); b.rect(-0.075, -0.935, 0.075, -0.965)
            b.line(-1.0, 0.05); b.line(-0.965, 0.15); b.line(-0.865, 0.3); b.line(-0.64, 0.33)
        default:
            return nil
        }
        return VectorSprite(fills: b.fills, rim: b.rim.isEmpty ? nil : b.rim, rimWidth: 0.025)
    }
}
