import CoreGraphics
import Foundation
import Metal
import simd

/// Rasterized symbol layers (`type: "symbol"`): one symbol's fills drawn as an anti-aliased coverage mask at the
/// on-screen pixel size (quantized like glyphs so zooms reuse rasters), tinted by the layer's fill in the shader.
final class SymbolRasterCache {
    struct Entry {
        let texture: MTLTexture
        /// Quad in layer units (y down, centred on the symbol's bounds), padding included.
        let rect: SIMD4<Float>
    }

    let device: MTLDevice
    private var sprites: [String: VectorSprite?] = [:]
    private var rasters: [String: Entry?] = [:]
    static let maxPixels: CGFloat = 4096

    init(device: MTLDevice) { self.device = device }

    func sprite(_ id: String, project: URL?) -> VectorSprite? {
        sprite(id, project: project, stamp: Self.stamp(project: project))
    }

    private func sprite(_ id: String, project: URL?, stamp: String) -> VectorSprite? {
        let key = "\(stamp)|\(id)"
        if let s = sprites[key] { return s }
        if sprites.count > 256 { sprites.removeAll() }
        let s = Symbols.sprite(id, project: project)
        sprites[key] = .some(s)
        return s
    }

    /// What a symbol id resolves to besides the id: the project, and the dates of the symbol folders the pack loader
    /// reads (symbol_save touches its folder), so a rewritten symbol or another project's symbol is not served stale.
    static func stamp(project: URL?) -> String {
        var s = fileDate(Symbols.userLibrary)
        if let project { s = "\(project.path)|\(s)|\(fileDate(project.appendingPathComponent("symbols")))" }
        return s
    }

    /// A file's or folder's modification date as text ("-" when it doesn't exist).
    static func fileDate(_ url: URL) -> String {
        guard let d = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date else {
            return "-"
        }
        return "\(d.timeIntervalSince1970)"
    }

    /// Layer-space size of a symbol drawn `size` px tall at full height (shorter symbols keep their proportion,
    /// as in repeaters: a pawn is 0.91 of a king).
    static func extent(_ s: VectorSprite, size: Double) -> CGSize {
        let b = s.bounds
        return CGSize(width: b.width * size, height: b.height * size)
    }

    func get(_ id: String, project: URL?, size: Double, pixelScale: Float) -> Entry? {
        let stamp = Self.stamp(project: project)
        guard size > 0, let s = sprite(id, project: project, stamp: stamp) else { return nil }
        let b = s.bounds
        guard !b.isNull, b.width > 0, b.height > 0 else { return nil }
        let ext = Self.extent(s, size: size)
        // Pixels per layer unit, quantized to 5% steps; capped so huge zooms don't allocate giant textures.
        var q = CGFloat(pow(1.05, (log(max(Double(pixelScale), 0.02)) / log(1.05)).rounded()))
        q = min(q, Self.maxPixels / max(ext.width, ext.height))
        let rasterH = max(1, (ext.height * q).rounded())
        // The size is part of the key: two sizes can share a raster height but cover different layer units.
        let key = "\(stamp)|\(id)|\(size)|\(Int(rasterH))"
        if let e = rasters[key] { return e }
        if rasters.count > 256 { rasters.removeAll() }
        let k = rasterH / b.height  // pixels per sprite unit
        q = rasterH / ext.height  // effective pixels per layer unit
        let pad: CGFloat = 2
        let w = Int(ceil(b.width * k + pad * 2)), h = Int(ceil(b.height * k + pad * 2))
        guard let ctx = CoverageMask.context(width: w, height: h) else { rasters[key] = .some(nil); return nil }
        // Sprite paths are y up (CoreGraphics), so the bitmap's first row is the symbol's top.
        ctx.translateBy(x: pad, y: pad)
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -b.minX, y: -b.minY)
        for f in s.fills { ctx.addPath(f) }
        ctx.fillPath(using: s.evenOdd ? .evenOdd : .winding)

        guard let tex = CoverageMask.texture(ctx, device: device) else { rasters[key] = .some(nil); return nil }
        let topPad = CGFloat(h) - pad - b.height * k
        let rect = SIMD4<Float>(
            Float(-ext.width / 2 - pad / q), Float(-ext.height / 2 - topPad / q),
            Float(CGFloat(w) / q), Float(CGFloat(h) / q))
        let e = Entry(texture: tex, rect: rect)
        rasters[key] = e
        return e
    }
}

extension Renderer {
    /// A standalone symbol layer: `{"type":"symbol","symbol":"chess/knight","size":300,"fill":"$fg"}`, centred on x,y.
    func drawSymbol(_ n: EvalNode, mvp: simd_float4x4, pxScale: Float, assets: URL?, enc: MTLRenderCommandEncoder) {
        guard
            let e = symbolRasters.get(
                n.str("symbol", Schema.defaultSymbol), project: assets?.deletingLastPathComponent(),
                size: n.num("size", 200), pixelScale: pxScale)
        else { return }
        let fill = n.color("fill") ?? foreground
        var u = TexU(
            mvp: mvp, unit: matrix_identity_float4x4, rect: e.rect, color: fill.linearPremultiplied(opacity: n.opacity),
            clip: TexU.noClip, mode: .zero)
        enc.setRenderPipelineState(texPSO)
        drawTexturedQuad(&u, texture: e.texture, enc: enc)
    }

    /// Local bounds of a symbol layer (nil when the symbol is unknown).
    func symbolBounds(_ n: EvalNode) -> CGRect? {
        guard
            let s = symbolRasters.sprite(
                n.str("symbol", Schema.defaultSymbol), project: currentAssets?.deletingLastPathComponent())
        else { return nil }
        let e = SymbolRasterCache.extent(s, size: n.num("size", 200))
        return CGRect(x: -e.width / 2, y: -e.height / 2, width: e.width, height: e.height)
    }
}
