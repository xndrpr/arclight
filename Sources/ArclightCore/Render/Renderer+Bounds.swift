import CoreGraphics
import Foundation

extension Renderer {
    /// Bounds of a 2D node in its own local space (before its world transform), for selection and gizmos.
    public func localBounds(_ n: EvalNode) -> CGRect? {
        switch n.node.type {
        case "shape":
            if n.str("shape", "rect") == "line" {
                let end = lineEnd(n)
                let r = CGRect(x: 0, y: 0, width: end.dx, height: end.dy).standardized
                let sw = n.num("strokeWidth", 4)
                return r.insetBy(dx: -sw / 2, dy: -sw / 2)
            }
            let w = n.num("width", 100), h = n.num("height", n.str("shape", "rect") == "ellipse" ? w : 100)
            return CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
        case "text":
            let l = layout(n)
            guard !l.glyphs.isEmpty else { return nil }
            let align = n.str("align", "left")
            let x = align == "center" ? -l.width / 2 : align == "right" ? -l.width : 0
            let top = l.lines.first?.top ?? 0, bottom = l.lines.last?.bottom ?? 0
            return CGRect(x: x, y: top, width: l.width, height: bottom - top)
        case "image":
            guard let tex = texture(src: n.str("src", ""), assets: currentAssets) else { return nil }
            let size = imageSize(n, texture: tex)
            return CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
        case "symbol":
            return symbolBounds(n)
        default:
            return nil
        }
    }
}
