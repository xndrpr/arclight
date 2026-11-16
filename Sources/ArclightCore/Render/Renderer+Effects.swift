import Foundation
import Metal
import simd

/// Pipelines and scratch targets for per-layer effects. A layer that has any (`needsEffects`) is drawn on its own
/// into `layer`, processed (adjust → blur → shadow / glow / outline under it → clip / mask), and composited onto the
/// 2D overlay with its blend mode. Layers without effects take the plain path and cost nothing extra.
final class FxKit {
    static let jfaFormat: MTLPixelFormat = .rgba32Float

    let adjust, blur, tint, mask, blend, over, add, jfaInit, jfaStep, outline, resample: MTLRenderPipelineState
    /// Reduced-resolution pairs for wide blurs, by "w×h".
    private var small: [String: (MTLTexture, MTLTexture)] = [:]

    init(
        plain: (String) throws -> MTLRenderPipelineState, over: (String) throws -> MTLRenderPipelineState,
        add: (String) throws -> MTLRenderPipelineState, jfa: (String) throws -> MTLRenderPipelineState
    ) throws {
        adjust = try plain("fx_adjust_fs")
        blur = try plain("fx_blur_fs")
        tint = try plain("fx_tint_fs")
        mask = try plain("fx_mask_fs")
        blend = try plain("fx_blend_fs")
        resample = try plain("fx_resample_fs")
        self.over = try over("fx_layer_fs")
        self.add = try add("fx_layer_fs")
        outline = try over("fx_outline_fs")
        jfaInit = try jfa("fx_jfa_init_fs")
        jfaStep = try jfa("fx_jfa_step_fs")
    }

    /// Two scratch textures of `w`×`h` for blurring at a fraction of the output resolution.
    func smallPair(device: MTLDevice, width w: Int, height h: Int) -> (MTLTexture, MTLTexture)? {
        let key = "\(w)x\(h)"
        if let p = small[key] { return p }
        func tex() -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Renderer.hdrFormat, width: max(w, 1), height: max(h, 1), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        guard let a = tex(), let b = tex() else { return nil }
        if small.count >= 4 { small.removeAll() }
        small[key] = (a, b)
        return (a, b)
    }

    /// Scratch textures for one output size. The five every effect needs are made up front; the clip base, mask and
    /// jump-flood (outline) textures only when a layer first uses them.
    final class Targets {
        let width, height: Int
        let layer, a, b, comp, tmp: MTLTexture
        private let make: (MTLPixelFormat) -> MTLTexture?
        private var _base, _mask, _jfaA, _jfaB: MTLTexture?

        init(width: Int, height: Int, make: @escaping (MTLPixelFormat) -> MTLTexture?) throws {
            self.width = width; self.height = height; self.make = make
            let f = Renderer.hdrFormat
            guard let l = make(f), let a = make(f), let b = make(f), let c = make(f), let t = make(f) else {
                throw RenderError.setup("effect textures")
            }
            layer = l; self.a = a; self.b = b; comp = c; tmp = t
        }

        private func lazy(_ slot: inout MTLTexture?, _ f: MTLPixelFormat) -> MTLTexture {
            if let t = slot { return t }
            let t = make(f) ?? tmp
            slot = t
            return t
        }
        var base: MTLTexture { lazy(&_base, Renderer.hdrFormat) }
        var maskTex: MTLTexture { lazy(&_mask, Renderer.hdrFormat) }
        var jfaA: MTLTexture { lazy(&_jfaA, FxKit.jfaFormat) }
        var jfaB: MTLTexture { lazy(&_jfaB, FxKit.jfaFormat) }
    }

    /// Recently used sizes (the viewer, thumbnails, exports) keep their targets, so alternating renders don't
    /// reallocate.
    private var bySize: [String: Targets] = [:]
    private var order: [String] = []

    func targets(device: MTLDevice, width w: Int, height h: Int) throws -> Targets {
        let key = "\(w)x\(h)"
        if let t = bySize[key] { return t }
        let t = try Targets(width: w, height: h) { fmt in
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: fmt, width: max(w, 1), height: max(h, 1), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        bySize[key] = t; order.append(key)
        if order.count > 3 { bySize[order.removeFirst()] = nil }
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
        // Every pass below only touches the layer's area plus the reach of its effects; the rest of each (cleared)
        // scratch texture stays transparent, so the result is the same as full-frame passes at a fraction of the cost.
        let region = effectRegion(n, scale: scale, width: t.width, height: t.height)

        // Ping-pong between a and b; `cur` holds the layer after each step.
        var cur = x.layer
        func other() -> MTLTexture { cur === x.a ? x.b : x.a }
        func blurred(_ src: MTLTexture, radius px: Float, into out: MTLTexture, via tmp: MTLTexture) {
            let sigma = max(px / 2, 0.5)
            // Wide blurs lose nothing at reduced resolution: ½ from σ 8 px, ¼ from σ 24 px.
            let f = sigma >= 24 ? 4 : sigma >= 8 ? 2 : 1
            let sw: Int = (t.width + f - 1) / f, sh: Int = (t.height + f - 1) / f
            if f > 1, let (sa, sb) = fx.smallPair(device: device, width: sw, height: sh) {
                let rx: Int = region.x / f, ry: Int = region.y / f
                let rw: Int = min(sw - rx, region.width / f + 2), rh: Int = min(sh - ry, region.height / f + 2)
                let r = MTLScissorRect(x: rx, y: ry, width: rw, height: rh)
                let st = SIMD2<Float>(1 / Float(sa.width), 1 / Float(sa.height))
                var down = SIMD4<Float>(texel.x * Float(f) / 4, texel.y * Float(f) / 4, 0, 0)
                fullscreen(
                    cb, target: sa, pso: fx.resample, textures: [src], params: &down, loadAction: .clear, scissor: r)
                let ss = sigma / Float(f), stride = max(1, ss * 3 / 48)
                var h = SIMD4<Float>(st.x, 0, ss, stride)
                fullscreen(cb, target: sb, pso: fx.blur, textures: [sa], params: &h, loadAction: .clear, scissor: r)
                var v = SIMD4<Float>(0, st.y, ss, stride)
                fullscreen(cb, target: sa, pso: fx.blur, textures: [sb], params: &v, loadAction: .clear, scissor: r)
                var up = SIMD4<Float>(0, 0, 0, 0)
                fullscreen(
                    cb, target: out, pso: fx.resample, textures: [sa], params: &up, loadAction: .clear, scissor: region)
                return
            }
            let stride = max(1, sigma * 3 / 48)  // at most ~97 taps per pass
            var h = SIMD4<Float>(texel.x, 0, sigma, stride)
            fullscreen(cb, target: tmp, pso: fx.blur, textures: [src], params: &h, loadAction: .clear, scissor: region)
            var v = SIMD4<Float>(0, texel.y, sigma, stride)
            fullscreen(cb, target: out, pso: fx.blur, textures: [tmp], params: &v, loadAction: .clear, scissor: region)
        }

        if let a = n.props["adjust"]?.object, !a.isEmpty {
            struct FxAdjust { var p0: SIMD4<Float>; var p1: SIMD4<Float> }
            var u = FxAdjust(
                p0: SIMD4(
                    Float(a["brightness"]?.double ?? 0), Float(a["contrast"]?.double ?? 1),
                    Float(a["saturation"]?.double ?? 1), Float((a["hue"]?.double ?? 0) * .pi / 180)),
                p1: SIMD4(Float(a["temperature"]?.double ?? 0), 0, 0, 0))
            let out = other()
            fullscreen(
                cb, target: out, pso: fx.adjust, textures: [cur], params: &u, loadAction: .clear, scissor: region)
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
            fullscreen(cb, target: free, pso: fx.tint, textures: [cur], params: &u, loadAction: .clear, scissor: region)
            let r = Float(d["blur"]?.double ?? 24) * s
            if r > 0.5 { blurred(free, radius: r, into: free, via: x.tmp) }
            var one = SIMD4<Float>(1, 0, 0, 0)
            fullscreen(
                cb, target: comp, pso: fx.over, textures: [free], params: &one, loadAction: .load, scissor: region)
        }
        if let g = e["glow"]?.object {
            let color = RGBA.parse(g["color"]) ?? foreground
            var u = FxTint(c: color.linearPremultiplied(), p: .zero)
            fullscreen(cb, target: free, pso: fx.tint, textures: [cur], params: &u, loadAction: .clear, scissor: region)
            blurred(free, radius: max(1, Float(g["radius"]?.double ?? 30) * s), into: free, via: x.tmp)
            var k = SIMD4<Float>(Float(g["intensity"]?.double ?? 1), 0, 0, 0)
            fullscreen(cb, target: comp, pso: fx.over, textures: [free], params: &k, loadAction: .load, scissor: region)
        }
        if let o = e["outline"]?.object, let w = o["width"]?.double, w > 0 {
            let width = Float(w) * s
            var p = SIMD4<Float>(0, 0, 0, 0)
            fullscreen(
                cb, target: x.jfaA, pso: fx.jfaInit, textures: [cur], params: &p, loadAction: .clear, scissor: region)
            var src = x.jfaA, dst = x.jfaB
            var k = 1
            while k < Int(width.rounded(.up)) + 1 { k <<= 1 }
            while k >= 1 {
                var step = SIMD4<Float>(Float(k), 0, 0, 0)
                fullscreen(
                    cb, target: dst, pso: fx.jfaStep, textures: [src], params: &step, loadAction: .clear,
                    scissor: region)
                swap(&src, &dst)
                k >>= 1
            }
            let color = RGBA.parse(o["color"]) ?? RGBA(1, 1, 1)
            struct FxOutline { var c: SIMD4<Float>; var p: SIMD4<Float> }
            var u = FxOutline(
                c: color.linearPremultiplied(opacity: o["opacity"]?.double ?? 1), p: SIMD4(width, 0, 0, 0))
            fullscreen(
                cb, target: comp, pso: fx.outline, textures: [src], params: &u, loadAction: .load, scissor: region)
        }
        var one = SIMD4<Float>(1, 0, 0, 0)
        fullscreen(cb, target: comp, pso: fx.over, textures: [cur], params: &one, loadAction: .load, scissor: region)

        // Clip to the layer below, then the mask.
        var result = comp
        if let base = clipBase {
            var p = SIMD4<Float>(0, 0, 0, 0)
            fullscreen(
                cb, target: x.tmp, pso: fx.mask, textures: [result, base], params: &p, loadAction: .clear,
                scissor: region)
            result = x.tmp
        }
        if let m = maskNode, let spec = n.props["mask"]?.object {
            drawIsolated(m, proj: proj, scale: scale, assets: assets, cb: cb, t: t, target: x.maskTex)
            var p = SIMD4<Float>(
                spec["mode"]?.string == "luma" ? 1 : 0, spec["invert"]?.bool == true ? 1 : 0, 0, 0)
            let out = result === x.tmp ? x.a : x.tmp
            fullscreen(
                cb, target: out, pso: fx.mask, textures: [result, x.maskTex], params: &p, loadAction: .clear,
                scissor: region)
            result = out
        }
        if result !== comp { blit(cb, from: result, to: comp, region: region) }

        // Onto the overlay with the blend mode.
        let mode = FxBlend.modes[n.props["blend"]?.string ?? "normal"] ?? 0
        if mode == 0 {
            fullscreen(
                cb, target: target, pso: fx.over, textures: [comp], params: &one, loadAction: .load, scissor: region)
        } else {
            var p = SIMD4<Float>(mode, 0, 0, 0)
            fullscreen(
                cb, target: x.tmp, pso: fx.blend, textures: [target, comp, world], params: &p, loadAction: .clear,
                scissor: region)
            blit(cb, from: x.tmp, to: target, region: region)
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

    func blit(_ cb: MTLCommandBuffer, from a: MTLTexture, to b: MTLTexture, region r: MTLScissorRect? = nil) {
        guard let e = cb.makeBlitCommandEncoder() else { return }
        if let r {
            e.copy(
                from: a, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: r.x, y: r.y, z: 0),
                sourceSize: MTLSize(width: r.width, height: r.height, depth: 1), to: b, destinationSlice: 0,
                destinationLevel: 0, destinationOrigin: MTLOrigin(x: r.x, y: r.y, z: 0))
        } else {
            e.copy(from: a, to: b)
        }
        e.endEncoding()
    }

    /// Output pixels a layer's effects can touch: its bounds (through its world transform) grown by the reach of
    /// outline, drop shadow (offset + blur), glow and blur, clamped to the target. The whole target when the layer
    /// has no measurable bounds.
    func effectRegion(_ n: EvalNode, scale: Double, width w: Int, height h: Int) -> MTLScissorRect {
        let full = MTLScissorRect(x: 0, y: 0, width: w, height: h)
        guard let b = localBounds(n), b.width.isFinite, b.height.isFinite else { return full }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for (x, y) in [(b.minX, b.minY), (b.maxX, b.minY), (b.minX, b.maxY), (b.maxX, b.maxY)] {
            let p = n.world * SIMD4<Float>(Float(x), Float(y), 0, 1)
            minX = min(minX, Double(p.x)); maxX = max(maxX, Double(p.x))
            minY = min(minY, Double(p.y)); maxY = max(maxY, Double(p.y))
        }
        let e = n.props["effects"]?.object ?? [:]
        var m = 0.0
        if let o = e["outline"]?.object { m += o["width"]?.double ?? 12 }
        if let d = e["dropShadow"]?.object {
            m += max(abs(d["x"]?.double ?? 0), abs(d["y"]?.double ?? 12)) + 2 * (d["blur"]?.double ?? 24)
        }
        if let g = e["glow"]?.object { m += 2 * (g["radius"]?.double ?? 30) }
        m += 2 * (e["blur"]?.double ?? 0)
        let pad = m * scale + 4
        let x0 = Int(max(0, (minX * scale - pad).rounded(.down)))
        let y0 = Int(max(0, (minY * scale - pad).rounded(.down)))
        let x1 = Int(min(Double(w), (maxX * scale + pad).rounded(.up)))
        let y1 = Int(min(Double(h), (maxY * scale + pad).rounded(.up)))
        guard x1 > x0, y1 > y0 else { return MTLScissorRect(x: 0, y: 0, width: 1, height: 1) }
        return MTLScissorRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}
