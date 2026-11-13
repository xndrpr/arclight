import Foundation
import Metal
import simd

/// Pipelines and scratch targets for per-layer effects. A layer that has any (`needsEffects`) is drawn on its own
/// into `layer`, processed (adjust → blur → shadow / glow / outline under it → clip / mask), and composited onto the
/// 2D overlay with its blend mode. Layers without effects take the plain path and cost nothing extra.
final class FxKit {
    static let jfaFormat: MTLPixelFormat = .rgba32Float

    let adjust, blur, tint, mask, blend, over, add, jfaInit, jfaStep, outline: MTLRenderPipelineState

    /// Scratch textures for the current output size.
    struct Targets {
        let width, height: Int
        let layer, a, b, comp, tmp, base, maskTex: MTLTexture
        let jfaA, jfaB: MTLTexture
    }
    var targets: Targets?

    init(
        plain: (String) throws -> MTLRenderPipelineState, over: (String) throws -> MTLRenderPipelineState,
        add: (String) throws -> MTLRenderPipelineState, jfa: (String) throws -> MTLRenderPipelineState
    ) throws {
        adjust = try plain("fx_adjust_fs")
        blur = try plain("fx_blur_fs")
        tint = try plain("fx_tint_fs")
        mask = try plain("fx_mask_fs")
        blend = try plain("fx_blend_fs")
        self.over = try over("fx_layer_fs")
        self.add = try add("fx_layer_fs")
        outline = try over("fx_outline_fs")
        jfaInit = try jfa("fx_jfa_init_fs")
        jfaStep = try jfa("fx_jfa_step_fs")
    }

    func targets(device: MTLDevice, width w: Int, height h: Int) throws -> Targets {
        if let t = targets, t.width == w, t.height == h { return t }
        func tex(_ fmt: MTLPixelFormat) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: fmt, width: max(w, 1), height: max(h, 1), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RenderError.setup("effect textures") }
            return t
        }
        let f = Renderer.hdrFormat
        let t = Targets(
            width: w, height: h, layer: try tex(f), a: try tex(f), b: try tex(f), comp: try tex(f), tmp: try tex(f),
            base: try tex(f), maskTex: try tex(f), jfaA: try tex(FxKit.jfaFormat), jfaB: try tex(FxKit.jfaFormat))
        targets = t
        return t
    }
}

/// Blend modes by name → `fx_blend_fs` mode number (0 = normal).
enum FxBlend {
    static let modes: [String: Float] = [
        "normal": 0, "multiply": 1, "screen": 2, "overlay": 3, "softLight": 4, "add": 5, "color": 6,
    ]
}

extension Renderer {
    /// Whether a 2D layer needs the effects path.
    static func needsEffects(_ n: EvalNode) -> Bool {
        guard Schema.effectTypes.contains(n.node.type) else { return false }
        if let b = n.props["blend"]?.string, b != "normal" { return true }
        if n.props["clip"]?.bool == true { return true }
        if n.props["mask"]?["node"]?.string != nil { return true }
        if let a = n.props["adjust"]?.object, !a.isEmpty { return true }
        if let e = n.props["effects"]?.object {
            if (e["blur"]?.double ?? 0) > 0 { return true }
            for k in ["outline", "dropShadow", "glow"] where e[k]?.object != nil { return true }
        }
        return false
    }

    /// Ids of layers used as another layer's mask (not drawn themselves), and of layers that a following
    /// `clip` layer clips to (their alpha is kept), in overlay draw order.
    static func maskAndClipBases(_ overlay: [EvalNode]) -> (masks: Set<String>, bases: Set<String>) {
        var masks = Set<String>(), bases = Set<String>()
        for n in overlay { if let m = n.props["mask"]?["node"]?.string { masks.insert(m) } }
        var lastBase: String?
        for n in overlay where !masks.contains(n.node.id) {
            if n.props["clip"]?.bool == true {
                if let b = lastBase { bases.insert(b) }
            } else {
                lastBase = n.node.id
            }
        }
        return (masks, bases)
    }

    /// Draws one 2D layer (no effects) into `target`, clearing it first.
    func drawIsolated(
        _ n: EvalNode, proj: simd_float4x4, scale: Double, assets: URL?, cb: MTLCommandBuffer, t: RenderTargets,
        target: MTLTexture
    ) {
        let mvp = proj * n.world
        let px = Float(scale) * M.maxScale(n.world)
        var fu = FrameU()
        guard let e = pass(cb, color: target, clear: .zero, coc: t.coc, clearCoc: false) else { return }
        e.setFragmentSamplerState(sampler, index: 0)
        e.setFragmentBytes(&fu, length: MemoryLayout<FrameU>.stride, index: 1)
        if n.node.type == "text" && glyphsTouch(n, pxScale: px) {
            e.endEncoding()
            drawTextUnion(n, mvp: mvp, pxScale: px, cb: cb, t: t, target: target)
            return
        }
        switch n.node.type {
        case "shape": drawShape(n, mvp: mvp, pxScale: px, enc: e)
        case "text": drawText(n, mvp: mvp, pxScale: px, enc: e)
        case "image": drawImage(n, mvp: mvp, assets: assets, enc: e)
        case "symbol": drawSymbol(n, mvp: mvp, pxScale: px, assets: assets, enc: e)
        default: break
        }
        e.endEncoding()
    }

    /// Draws a layer with its effects onto `target` (the 2D overlay). `clipBase`: the alpha it clips to.
    /// `maskNode`: its mask layer. Leaves the composited layer (before blending) in `fx.targets.comp`.
    func drawWithEffects(
        _ n: EvalNode, proj: simd_float4x4, scale: Double, assets: URL?, cb: MTLCommandBuffer, t: RenderTargets,
        target: MTLTexture, world: MTLTexture, clipBase: MTLTexture?, maskNode: EvalNode?
    ) {
        guard let x = try? fx.targets(device: device, width: t.width, height: t.height) else { return }
        let s = Float(scale)
        let texel = SIMD2<Float>(1 / Float(t.width), 1 / Float(t.height))
        drawIsolated(n, proj: proj, scale: scale, assets: assets, cb: cb, t: t, target: x.layer)

        // Ping-pong between a and b; `cur` holds the layer after each step.
        var cur = x.layer
        func other() -> MTLTexture { cur === x.a ? x.b : x.a }
        func blurred(_ src: MTLTexture, radius px: Float, into out: MTLTexture, via tmp: MTLTexture) {
            let sigma = max(px / 2, 0.5)
            let stride = max(1, sigma * 3 / 48)  // at most ~97 taps per pass
            var h = SIMD4<Float>(texel.x, 0, sigma, stride)
            fullscreen(cb, target: tmp, pso: fx.blur, textures: [src], params: &h, loadAction: .clear)
            var v = SIMD4<Float>(0, texel.y, sigma, stride)
            fullscreen(cb, target: out, pso: fx.blur, textures: [tmp], params: &v, loadAction: .clear)
        }

        if let a = n.props["adjust"]?.object, !a.isEmpty {
            struct FxAdjust { var p0: SIMD4<Float>; var p1: SIMD4<Float> }
            var u = FxAdjust(
                p0: SIMD4(
                    Float(a["brightness"]?.double ?? 0), Float(a["contrast"]?.double ?? 1),
                    Float(a["saturation"]?.double ?? 1), Float((a["hue"]?.double ?? 0) * .pi / 180)),
                p1: SIMD4(Float(a["temperature"]?.double ?? 0), 0, 0, 0))
            let out = other()
            fullscreen(cb, target: out, pso: fx.adjust, textures: [cur], params: &u, loadAction: .clear)
            cur = out
        }
        let e = n.props["effects"]?.object ?? [:]
        if let r = e["blur"]?.double, r > 0 {
            let out = other()
            blurred(cur, radius: Float(r) * s, into: out, via: x.tmp)
            cur = out
        }

        // Composite: drop shadow, glow, outline, then the layer, into comp.
        let comp = x.comp
        clear(cb, comp)
        struct FxTint { var c: SIMD4<Float>; var p: SIMD4<Float> }
        let free = cur === x.a ? x.b : (cur === x.b ? x.a : x.a)  // a scratch texture not holding the layer
        if let d = e["dropShadow"]?.object {
            let color = RGBA.parse(d["color"]) ?? RGBA(0, 0, 0)
            var u = FxTint(
                c: color.linearPremultiplied(opacity: d["opacity"]?.double ?? 0.6),
                p: SIMD4(0, 0, Float(d["x"]?.double ?? 0) * s * texel.x, Float(d["y"]?.double ?? 12) * s * texel.y))
            fullscreen(cb, target: free, pso: fx.tint, textures: [cur], params: &u, loadAction: .clear)
            let r = Float(d["blur"]?.double ?? 24) * s
            if r > 0.5 { blurred(free, radius: r, into: free, via: x.tmp) }
            var one = SIMD4<Float>(1, 0, 0, 0)
            fullscreen(cb, target: comp, pso: fx.over, textures: [free], params: &one, loadAction: .load)
        }
        if let g = e["glow"]?.object {
            let color = RGBA.parse(g["color"]) ?? foreground
            var u = FxTint(c: color.linearPremultiplied(), p: .zero)
            fullscreen(cb, target: free, pso: fx.tint, textures: [cur], params: &u, loadAction: .clear)
            blurred(free, radius: max(1, Float(g["radius"]?.double ?? 30) * s), into: free, via: x.tmp)
            var k = SIMD4<Float>(Float(g["intensity"]?.double ?? 1), 0, 0, 0)
            fullscreen(cb, target: comp, pso: fx.over, textures: [free], params: &k, loadAction: .load)
        }
        if let o = e["outline"]?.object, let w = o["width"]?.double, w > 0 {
            let width = Float(w) * s
            var p = SIMD4<Float>(0, 0, 0, 0)
            fullscreen(cb, target: x.jfaA, pso: fx.jfaInit, textures: [cur], params: &p, loadAction: .clear)
            var src = x.jfaA, dst = x.jfaB
            var k = 1
            while k < Int(width.rounded(.up)) + 1 { k <<= 1 }
            while k >= 1 {
                var step = SIMD4<Float>(Float(k), 0, 0, 0)
                fullscreen(cb, target: dst, pso: fx.jfaStep, textures: [src], params: &step, loadAction: .clear)
                swap(&src, &dst)
                k >>= 1
            }
            let color = RGBA.parse(o["color"]) ?? RGBA(1, 1, 1)
            struct FxOutline { var c: SIMD4<Float>; var p: SIMD4<Float> }
            var u = FxOutline(c: color.linearPremultiplied(opacity: o["opacity"]?.double ?? 1), p: SIMD4(width, 0, 0, 0))
            fullscreen(cb, target: comp, pso: fx.outline, textures: [src], params: &u, loadAction: .load)
        }
        var one = SIMD4<Float>(1, 0, 0, 0)
        fullscreen(cb, target: comp, pso: fx.over, textures: [cur], params: &one, loadAction: .load)

        // Clip to the layer below, then the mask.
        var result = comp
        if let base = clipBase {
            var p = SIMD4<Float>(0, 0, 0, 0)
            fullscreen(cb, target: x.tmp, pso: fx.mask, textures: [result, base], params: &p, loadAction: .clear)
            result = x.tmp
        }
        if let m = maskNode, let spec = n.props["mask"]?.object {
            drawIsolated(m, proj: proj, scale: scale, assets: assets, cb: cb, t: t, target: x.maskTex)
            var p = SIMD4<Float>(
                spec["mode"]?.string == "luma" ? 1 : 0, spec["invert"]?.bool == true ? 1 : 0, 0, 0)
            let out = result === x.tmp ? x.a : x.tmp
            fullscreen(cb, target: out, pso: fx.mask, textures: [result, x.maskTex], params: &p, loadAction: .clear)
            result = out
        }
        if result !== comp { blit(cb, from: result, to: comp) }

        // Onto the overlay with the blend mode.
        let mode = FxBlend.modes[n.props["blend"]?.string ?? "normal"] ?? 0
        if mode == 0 {
            fullscreen(cb, target: target, pso: fx.over, textures: [comp], params: &one, loadAction: .load)
        } else {
            var p = SIMD4<Float>(mode, 0, 0, 0)
            fullscreen(cb, target: x.tmp, pso: fx.blend, textures: [target, comp, world], params: &p, loadAction: .clear)
            blit(cb, from: x.tmp, to: target)
        }
    }

    /// Clears a texture to transparent (an empty pass: drawing a scratch texture × 0 would keep its NaNs).
    func clear(_ cb: MTLCommandBuffer, _ tex: MTLTexture) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = tex
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        cb.makeRenderCommandEncoder(descriptor: rp)?.endEncoding()
    }

    func blit(_ cb: MTLCommandBuffer, from a: MTLTexture, to b: MTLTexture) {
        guard let e = cb.makeBlitCommandEncoder() else { return }
        e.copy(from: a, to: b)
        e.endEncoding()
    }
}
