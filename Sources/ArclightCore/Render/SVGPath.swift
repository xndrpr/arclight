import CoreGraphics
import Foundation

/// Parses SVG path data (`d`): M L H V C S Q T A Z, absolute and relative, implicit repeats.
/// Output is in SVG coordinates (y down); callers flip as needed.
enum SVGPath {
    enum ParseError: Error, CustomStringConvertible {
        case bad(String)
        var description: String { if case .bad(let s) = self { return "SVG path: \(s)" }; return "SVG path" }
    }

    static func parse(_ d: String) throws -> CGPath {
        let chars = Array(d.utf8)
        var i = 0
        let path = CGMutablePath()
        var cur = CGPoint.zero, start = CGPoint.zero
        var lastCtrl: CGPoint? = nil, lastCmd: UInt8 = 0
        var cmd: UInt8 = 0

        func skip() {
            while i < chars.count, chars[i] == 32 || chars[i] == 44 || chars[i] == 9 || chars[i] == 10 || chars[i] == 13
            { i += 1 }
        }
        func isCmd(_ c: UInt8) -> Bool { "MmLlHhVvCcSsQqTtAaZz".utf8.contains(c) }
        func hasNumber() -> Bool { skip(); return i < chars.count && !isCmd(chars[i]) }
        func num() throws -> CGFloat {
            skip()
            let s = i
            if i < chars.count, chars[i] == 43 || chars[i] == 45 { i += 1 }
            var dot = false, digits = false
            while i < chars.count {
                let c = chars[i]
                if c >= 48 && c <= 57 {
                    digits = true; i += 1
                } else if c == 46 && !dot {
                    dot = true; i += 1
                } else if (c == 101 || c == 69) && digits {
                    i += 1; if i < chars.count, chars[i] == 43 || chars[i] == 45 { i += 1 }
                    while i < chars.count, chars[i] >= 48 && chars[i] <= 57 { i += 1 }
                    break
                } else {
                    break
                }
            }
            guard digits, let v = Double(String(decoding: chars[s..<i], as: UTF8.self)) else {
                throw ParseError.bad("expected number at \(s)")
            }
            return CGFloat(v)
        }
        func flag() throws -> Bool {
            skip()
            guard i < chars.count, chars[i] == 48 || chars[i] == 49 else {
                throw ParseError.bad("expected arc flag at \(i)")
            }
            defer { i += 1 }
            return chars[i] == 49
        }

        skip()
        while i < chars.count {
            if isCmd(chars[i]) { cmd = chars[i]; i += 1 }
            if cmd == 0 || (lastCmd == 0 && cmd | 0x20 != 109) { throw ParseError.bad("must start with M") }
            let rel = cmd >= 97
            let base = rel ? cur : .zero
            switch cmd | 0x20 {  // lowercase
            case 109:  // m
                let p = CGPoint(x: try num() + base.x, y: try num() + base.y)
                path.move(to: p); cur = p; start = p
                cmd = rel ? 108 : 76  // following pairs are lineto
            case 108:  // l
                let p = CGPoint(x: try num() + base.x, y: try num() + base.y); path.addLine(to: p); cur = p
            case 104:  // h
                let x = try num() + (rel ? cur.x : 0); cur = CGPoint(x: x, y: cur.y); path.addLine(to: cur)
            case 118:  // v
                let y = try num() + (rel ? cur.y : 0); cur = CGPoint(x: cur.x, y: y); path.addLine(to: cur)
            case 99:  // c
                let c1 = CGPoint(x: try num() + base.x, y: try num() + base.y)
                let c2 = CGPoint(x: try num() + base.x, y: try num() + base.y)
                let p = CGPoint(x: try num() + base.x, y: try num() + base.y)
                path.addCurve(to: p, control1: c1, control2: c2); lastCtrl = c2; cur = p
            case 115:  // s
                let c1 = (lastCmd | 0x20 == 99 || lastCmd | 0x20 == 115) ? reflect(lastCtrl ?? cur, cur) : cur
                let c2 = CGPoint(x: try num() + base.x, y: try num() + base.y)
                let p = CGPoint(x: try num() + base.x, y: try num() + base.y)
                path.addCurve(to: p, control1: c1, control2: c2); lastCtrl = c2; cur = p
            case 113:  // q
                let c = CGPoint(x: try num() + base.x, y: try num() + base.y)
                let p = CGPoint(x: try num() + base.x, y: try num() + base.y)
                path.addQuadCurve(to: p, control: c); lastCtrl = c; cur = p
            case 116:  // t
                let c = (lastCmd | 0x20 == 113 || lastCmd | 0x20 == 116) ? reflect(lastCtrl ?? cur, cur) : cur
                let p = CGPoint(x: try num() + base.x, y: try num() + base.y)
                path.addQuadCurve(to: p, control: c); lastCtrl = c; cur = p
            case 97:  // a
                let rx = try num(), ry = try num(), rot = try num()
                let large = try flag(), sweep = try flag()
                let p = CGPoint(x: try num() + base.x, y: try num() + base.y)
                arc(path, from: cur, to: p, rx: rx, ry: ry, rotation: rot, large: large, sweep: sweep); cur = p
            case 122:  // z
                path.closeSubpath(); cur = start
            default:
                throw ParseError.bad("unknown command")
            }
            lastCmd = cmd
            if cmd | 0x20 != 99 && cmd | 0x20 != 115 && cmd | 0x20 != 113 && cmd | 0x20 != 116 { lastCtrl = nil }
            if cmd | 0x20 == 122 {
                skip(); if i < chars.count, !isCmd(chars[i]) { throw ParseError.bad("numbers after Z") }
            } else if !hasNumber() {
                continue
            }
        }
        return path
    }

    static func reflect(_ c: CGPoint, _ about: CGPoint) -> CGPoint {
        CGPoint(x: 2 * about.x - c.x, y: 2 * about.y - c.y)
    }

    /// SVG endpoint arc → cubic Béziers (SVG spec F.6.5).
    static func arc(
        _ path: CGMutablePath, from p0: CGPoint, to p1: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
        rotation: CGFloat, large: Bool, sweep: Bool
    ) {
        var rx = abs(rxIn), ry = abs(ryIn)
        guard rx > 0, ry > 0, p0 != p1 else { path.addLine(to: p1); return }
        let phi = rotation * .pi / 180, cp = cos(phi), sp = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1 = cp * dx + sp * dy, y1 = -sp * dx + cp * dy
        let lambda = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var co = sqrt(max(0, num / den))
        if large == sweep { co = -co }
        let cxp = co * rx * y1 / ry, cyp = -co * ry * x1 / rx
        let cx = cp * cxp - sp * cyp + (p0.x + p1.x) / 2, cy = sp * cxp + cp * cyp + (p0.y + p1.y) / 2
        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let a = atan2(ux * vy - uy * vx, ux * vx + uy * vy); return a
        }
        let t1 = angle(1, 0, (x1 - cxp) / rx, (y1 - cyp) / ry)
        var dt = angle((x1 - cxp) / rx, (y1 - cyp) / ry, (-x1 - cxp) / rx, (-y1 - cyp) / ry)
        if !sweep && dt > 0 { dt -= 2 * .pi } else if sweep && dt < 0 { dt += 2 * .pi }
        let segs = max(1, Int(ceil(abs(dt) / (.pi / 2))))
        let step = dt / CGFloat(segs)
        let k = 4.0 / 3.0 * tan(step / 4)
        func pt(_ t: CGFloat) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cp - ry * sin(t) * sp, y: cy + rx * cos(t) * sp + ry * sin(t) * cp)
        }
        func deriv(_ t: CGFloat) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cp - ry * cos(t) * sp, y: -rx * sin(t) * sp + ry * cos(t) * cp)
        }
        var t = t1
        for _ in 0..<segs {
            let a = pt(t), b = pt(t + step), da = deriv(t), db = deriv(t + step)
            path.addCurve(
                to: b, control1: CGPoint(x: a.x + k * da.x, y: a.y + k * da.y),
                control2: CGPoint(x: b.x - k * db.x, y: b.y - k * db.y))
            t += step
        }
    }

    /// Builds a sprite from SVG item fields: `path` (fill), optional `rim` (stroked highlight),
    /// `rimWidth` (fraction of height), `fillRule` "nonzero"|"evenodd". The bottom of the path's
    /// bounds stands on the floor; it is centred horizontally on its bounds.
    static func sprite(_ item: [String: JSONValue]) throws -> VectorSprite {
        guard let d = item["path"]?.string else { throw ParseError.bad("missing path") }
        let raw = try parse(d)
        let rimRaw = try item["rim"]?.string.map(parse)
        let b = raw.boundingBoxOfPath
        guard b.height > 0, b.width > 0 else { throw ParseError.bad("path is empty") }
        // Normalise: height 1, base centre at origin, flip y (SVG y down → CG y up).
        var t = CGAffineTransform(scaleX: 1 / b.height, y: -1 / b.height).translatedBy(x: -b.midX, y: -b.maxY)
        let fill = raw.copy(using: &t)!
        let rim = rimRaw.flatMap { $0.copy(using: &t) }
        return VectorSprite(
            fills: [fill], rim: rim, rimWidth: CGFloat(item["rimWidth"]?.double ?? 0.025),
            evenOdd: item["fillRule"]?.string == "evenodd")
    }
}
