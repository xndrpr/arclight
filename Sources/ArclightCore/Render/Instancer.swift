import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Metal
import simd

/// One copy of a repeater item, in the repeater's local space (ground = local xz plane, y = 0, "up" = -y).
struct Instance {
    var pos: SIMD3<Float>
    var scale: Float = 1
    var opacity: Float = 1
    var lit: Float = 0
    var variant: Int = 0
    var color: RGBA?
    var yaw: Float = 0
}

enum InstanceLayout {
    /// Same hash as the JS `rand(seed)`, so expressions and layouts agree.
    static func rand(_ s: Double) -> Double { let x = sin(s * 12.9898 + 78.233) * 43758.5453; return x - floor(x) }

    static func positions(_ n: EvalNode) -> [SIMD3<Float>] {
        let layout = n.str("layout", "grid")
        let seed = n.num("seed", 1)
        var pts: [SIMD3<Float>] = []
        func pair(_ k: String, _ d: Double) -> (Double, Double) {
            if let a = n.props[k]?.doubles, a.count >= 2 { return (a[0], a[1]) }
            let v = n.num(k, d); return (v, v)
        }
        switch layout {
        case "scatter":
            let count = Int(n.num("count", 100)), (w, d) = pair("area", 1000)
            for i in 0..<max(count, 0) {
                let x = (rand(Double(i) * 3 + seed * 17) - 0.5) * w
                let z = (rand(Double(i) * 3 + 1 + seed * 17) - 0.5) * d
                pts.append(SIMD3(Float(x), 0, Float(z)))
            }
        case "ring":
            let count = Int(n.num("count", 12)), r = n.num("radius", 300)
            for i in 0..<max(count, 0) {
                let a = Double(i) / Double(max(count, 1)) * 2 * .pi
                pts.append(SIMD3(Float(cos(a) * r), 0, Float(sin(a) * r)))
            }
        case "points":
            for p in n.props["points"]?.array ?? [] {
                guard let d = p.doubles else { continue }
                if d.count >= 3 {
                    pts.append(SIMD3(Float(d[0]), Float(d[1]), Float(d[2])))
                } else if d.count == 2 {
                    pts.append(SIMD3(Float(d[0]), 0, Float(d[1])))
                }
            }
        default:  // grid
            let cols = max(1, Int(n.num("cols", 10))), rows = max(1, Int(n.num("rows", 10)))
            let (sx, sz) = pair("spacing", 100)
            for r in 0..<rows {
                for c in 0..<cols {
                    pts.append(
                        SIMD3(
                            Float((Double(c) - Double(cols - 1) / 2) * sx), 0,
                            Float((Double(r) - Double(rows - 1) / 2) * sz)))
                }
            }
            let jitter = n.num("jitter", 0)
            if jitter > 0 {
                for i in pts.indices {
                    pts[i].x += Float((rand(Double(i) * 2 + seed * 31) - 0.5) * jitter * sx)
                    pts[i].z += Float((rand(Double(i) * 2 + 1 + seed * 31) - 0.5) * jitter * sz)
                }
            }
        }
        return pts
    }

    /// Builds instances: layout positions, weighted variant pick, then per-instance props
    /// (`instance` object: constants, keyframes or expressions using `i`).
    static func build(
        _ n: EvalNode, items: [[String: JSONValue]], evaluator: Evaluator, T: Double, duration: Double
    ) -> [Instance] {
        let pts = positions(n)
        let count = pts.count
        let seed = n.num("seed", 1)
        let weights = items.map { max($0["weight"]?.double ?? 1, 0) }
        let total = weights.reduce(0, +)
        var out = pts.enumerated().map { i, p -> Instance in
            var inst = Instance(pos: p)
            if items.count > 1, total > 0 {
                var x = rand(Double(i) * 7.31 + seed * 3.7) * total
                for (k, w) in weights.enumerated() { if x < w { inst.variant = k; break }; x -= w; inst.variant = k }
            }
            return inst
        }
        guard let spec = n.props["instance"]?.object, count > 0 else { return out }
        for (key, raw) in spec {
            guard let prop = try? Prop(json: raw) else { continue }
            var values: [JSONValue]
            switch prop {
            case .expr(let src):
                if key == "color" {
                    values = (0..<count).map {
                        evaluator.resolve(evaluator.expr.eval(src, t: n.t, T: T, i: $0, d: duration, n: count))
                    }
                } else {
                    guard let nums = evaluator.expr.evalBatch(src, t: n.t, T: T, d: duration, n: count) else {
                        continue
                    }
                    values = nums.map { $0.isFinite ? .number($0) : .null }
                }
            default:
                values = Array(repeating: evaluator.value(prop, t: n.t, T: T, duration: duration), count: count)
            }
            for i in 0..<count {
                let v = values[i]
                switch key {
                case "x": out[i].pos.x += Float(v.double ?? 0)
                case "y": out[i].pos.y += Float(v.double ?? 0)
                case "z": out[i].pos.z += Float(v.double ?? 0)
                case "scale": out[i].scale *= Float(v.double ?? 1)
                case "opacity": out[i].opacity *= Float(v.double ?? 1)
                case "lit": out[i].lit = Float(v.double ?? 0)
                case "variant":
                    if let d = v.double, !items.isEmpty { out[i].variant = max(0, min(items.count - 1, Int(d))) }
                case "color": out[i].color = RGBA.parse(v)
                case "yaw", "rotation": out[i].yaw = Float(v.double ?? 0)
                case "visible": if v.bool == false { out[i].opacity = 0 }
                default: break
                }
            }
        }
        return out
    }
}

/// Repeater items rasterized side by side into one mipmapped texture, so a whole crowd
/// is one depth-sorted instanced draw.
final class SpriteAtlas {
    /// `rimOffset`: v offset from the silhouette to its rim-highlight copy (0 = no rim layer).
    struct Cell { var uv: SIMD4<Float>; var aspect: Float; var height: Float; var rimOffset: Float = 0 }
    let texture: MTLTexture
    let cells: [Cell]

    init(texture: MTLTexture, cells: [Cell]) { self.texture = texture; self.cells = cells }

    /// The cell an instance draws (its variant, clamped to the items there are).
    func cell(for inst: Instance) -> Cell { cells[min(inst.variant, cells.count - 1)] }

    static let defaultGlyphFont = "AppleSymbols"

    /// Layout: one row of cells (silhouettes). When any item has a rim, a second row below holds
    /// the rim strokes at the same x, exactly half the texture height away.
    static func build(
        items: [[String: JSONValue]], rasterHeight R: Int, device: MTLDevice, queue: MTLCommandQueue, assets: URL?
    ) -> SpriteAtlas? {
        let pad = 10
        enum Kind { case glyph(CTLine, CGRect), image(CGImage), shape(String), vector(VectorSprite) }
        var kinds: [(Kind, Int, Float)] = []  // kind, pixel width, world height
        for item in items {
            let worldH = Float(item["height"]?.double ?? 100)
            var vec: VectorSprite?
            if let sym = item["symbol"]?.string {
                vec = Symbols.sprite(sym, project: assets?.deletingLastPathComponent())
            } else if let name = item["piece"]?.string {
                vec = Symbols.sprite("chess/\(name)", project: nil)
            }  // legacy alias
            else if item["path"] != nil {
                vec = try? SVGPath.sprite(item)
            }
            if var v = vec {
                if item["rim"]?.bool == false { v.rim = nil }
                if let rw = item["rimWidth"]?.double { v.rimWidth = CGFloat(rw) }
                let margin = v.rim == nil ? 0 : v.rimWidth
                // Paths are in units of the item height; keep relative proportions (a pawn is 0.91 of a king).
                let bh = v.bounds.height
                kinds.append(
                    (.vector(v), max(1, Int(ceil((v.bounds.width + margin) / bh * CGFloat(R)))), worldH * Float(bh)))
            } else if let g = item["glyph"]?.string {
                let fontName = item["font"]?.string ?? defaultGlyphFont
                let probe = CTLineCreateWithAttributedString(
                    NSAttributedString(
                        string: g,
                        attributes: [
                            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                                fontName as CFString, 100, nil)
                        ]))
                let pb = CTLineGetBoundsWithOptions(probe, .useGlyphPathBounds)
                guard pb.height > 0 else { kinds.append((.shape("rect"), R, worldH)); continue }
                let size = 100 * CGFloat(R) / pb.height
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(
                        string: g,
                        attributes: [
                            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
                                fontName as CFString, size, nil),
                            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                                red: 1, green: 1, blue: 1, alpha: 1),
                        ]))
                let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
                kinds.append((.glyph(line, b), max(1, Int(ceil(b.width))), worldH))
            } else if let src = item["src"]?.string {
                let url = AssetPath.url(src, assets: assets)
                if let isrc = CGImageSourceCreateWithURL(url as CFURL, nil),
                    let img = CGImageSourceCreateImageAtIndex(isrc, 0, nil)
                {
                    kinds.append(
                        (.image(img), max(1, Int(Double(R) * Double(img.width) / Double(max(img.height, 1)))), worldH))
                } else {
                    kinds.append((.shape("rect"), R, worldH))
                }
            } else {
                let w = item["width"]?.double ?? Double(worldH)
                kinds.append(
                    (.shape(item["shape"]?.string ?? "ellipse"), max(1, Int(Double(R) * w / Double(worldH))), worldH))
            }
        }
        guard !kinds.isEmpty else { return nil }
        let hasRim = kinds.contains {
            if case .vector(let v) = $0.0 { return v.rim != nil }; return false
        }
        let rowH = R + pad * 2
        let W = kinds.reduce(pad) { $0 + $1.1 + pad }, H = rowH * (hasRim ? 2 : 1)
        guard W <= 16384,
            let ctx = CGContext(
                data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.setFillColor(white)
        ctx.setStrokeColor(white)
        // CG is y-up: the silhouette row is the top row of the texture.
        let y0 = H - rowH + pad, rimY0 = pad
        var x = pad, cells: [Cell] = []
        for (idx, (kind, w, worldH)) in kinds.enumerated() {
            let widthScale = Float(items[idx]["widthScale"]?.double ?? 1)
            let rect = CGRect(x: x, y: y0, width: w, height: R)
            var rimOffset: Float = 0
            switch kind {
            case .glyph(let line, let b):
                ctx.textPosition = CGPoint(x: CGFloat(x) - b.minX, y: CGFloat(y0) - b.minY)
                CTLineDraw(line, ctx)
            case .image(let img): ctx.draw(img, in: rect)
            case .shape(let s): if s == "rect" { ctx.fill(rect) } else { ctx.fillEllipse(in: rect) }
            case .vector(let v):
                let b = v.bounds
                let margin = v.rim == nil ? 0 : v.rimWidth / 2
                let k = CGFloat(R) / b.height  // raster px per path unit
                func place(_ baseY: Int) {
                    ctx.translateBy(x: CGFloat(x) + (margin - b.minX) * k, y: CGFloat(baseY) - b.minY * k)
                    ctx.scaleBy(x: k, y: k)
                }
                ctx.saveGState(); place(y0)
                for f in v.fills { ctx.addPath(f); ctx.fillPath(using: v.evenOdd ? .evenOdd : .winding) }
                ctx.restoreGState()
                if let rim = v.rim {
                    ctx.saveGState(); place(rimY0)
                    ctx.setLineWidth(v.rimWidth); ctx.setLineCap(.round); ctx.setLineJoin(.round)
                    ctx.addPath(rim); ctx.strokePath()
                    ctx.restoreGState()
                    rimOffset = Float(rowH) / Float(H)
                }
            }
            let top = H - y0 - R  // texture rows are top-down
            cells.append(
                Cell(
                    uv: SIMD4(
                        Float(x) / Float(W), Float(top) / Float(H), Float(x + w) / Float(W), Float(top + R) / Float(H)),
                    aspect: Float(w) / Float(R) * widthScale, height: worldH, rimOffset: rimOffset))
            x += w + pad
        }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm_srgb, width: W, height: H, mipmapped: true)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc), let data = ctx.data else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0, withBytes: data, bytesPerRow: W * 4)
        if let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: tex); blit.endEncoding(); cb.commit(); cb.waitUntilCompleted()
        }
        return SpriteAtlas(texture: tex, cells: cells)
    }
}
