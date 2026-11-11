import CoreGraphics
import Foundation
import Metal
import simd

extension Renderer {
    /// Expands `{v}` with the numeric `value` prop (count-ups): `decimals`, `thousands` separator.
    static func formatText(_ n: EvalNode) -> String {
        var text = n.str("text", "")
        if text.contains("{v}") {
            let v = n.num("value", 0), dec = max(0, Int(n.num("decimals", 0)))
            var s = String(format: "%.\(dec)f", v)
            if let sep = n.props["thousands"]?.string, !sep.isEmpty {
                let parts = s.split(separator: ".", maxSplits: 1).map(String.init)
                var intPart = parts[0], neg = false
                if intPart.hasPrefix("-") { neg = true; intPart.removeFirst() }
                var grouped = ""
                for (i, c) in intPart.reversed().enumerated() {
                    if i > 0 && i % 3 == 0 { grouped.append(contentsOf: sep.reversed()) }; grouped.append(c)
                }
                s = (neg ? "-" : "") + String(grouped.reversed()) + (parts.count > 1 ? "." + parts[1] : "")
            }
            text = text.replacingOccurrences(of: "{v}", with: s)
        }
        return n.bool("uppercase", false) ? text.uppercased() : text
    }

    func layout(_ n: EvalNode) -> TextLayout {
        let text = Renderer.formatText(n)
        let font = n.str("font", evaluator.resolve("$display").string ?? "Helvetica-Bold")
        let size = n.num("size", 100), tracking = n.num("tracking", 0), lh = n.num("lineHeight", 1.1)
        let align = n.str("align", "left")
        let tabular = n.bool("tabular", false)
        let key = "\(text)|\(font)|\(size)|\(tracking)|\(lh)|\(align)|\(tabular)"
        if let l = layouts[key] { return l }
        if layouts.count > 512 { layouts.removeAll() }
        let l = TextLayout(
            text: text, fontName: font, size: size, tracking: tracking, lineHeight: lh, align: align, tabular: tabular)
        layouts[key] = l
        return l
    }

    /// One glyph of a text layer, ready to draw: its uniforms (tinted with the layer's colour and opacity), coverage
    /// texture, and its own reveal alpha.
    struct GlyphQuad {
        var u: TexU
        let texture: MTLTexture
        let unitAlpha: Double
    }

    func textColor(_ n: EvalNode) -> RGBA { n.color("color") ?? n.color("fill") ?? foreground }

    func drawText(_ n: EvalNode, mvp: simd_float4x4, pxScale: Float, enc: MTLRenderCommandEncoder) {
        enc.setRenderPipelineState(texPSO)
        for var q in glyphQuads(n, mvp: mvp, pxScale: pxScale) {
            drawTexturedQuad(&q.u, texture: q.texture, enc: enc)
        }
    }

    /// Whether negative tracking pushes neighbouring glyphs within half an output pixel of each other, where edges
    /// blended one glyph at a time would leave a lighter seam at the joint. Text at zero or positive tracking keeps
    /// the font's own spacing and takes the cheaper path (its ink boxes overlap only for kerned pairs, which don't
    /// touch).
    func glyphsTouch(_ n: EvalNode, pxScale: Float) -> Bool {
        n.num("tracking", 0) < 0 && layout(n).minInkGap < 0.5 / CGFloat(max(pxScale, 1e-6))
    }

    /// Draws a text layer whose glyphs touch: their coverage is summed into `t.cover` in a pass of its own, then
    /// tinted onto `target` at once, so a joint is as solid as the glyphs. Where glyphs don't overlap this equals
    /// `drawText`. Call it between render passes.
    func drawTextUnion(
        _ n: EvalNode, mvp: simd_float4x4, pxScale: Float, cb: MTLCommandBuffer, t: RenderTargets,
        target: MTLTexture
    ) {
        let quads = glyphQuads(n, mvp: mvp, pxScale: pxScale)
        guard !quads.isEmpty else { return }
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = t.cover
        rp.colorAttachments[0].loadAction = .clear
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(coverPSO)
        enc.setFragmentSamplerState(sampler, index: 0)
        for var q in quads {
            q.u.color = SIMD4(0, 0, 0, Float(q.unitAlpha))
            drawTexturedQuad(&q.u, texture: q.texture, enc: enc)
        }
        enc.endEncoding()
        var c = textColor(n).linearPremultiplied(opacity: n.opacity)
        fullscreen(cb, target: target, pso: unionPSO, textures: [t.cover], params: &c, loadAction: .load)
    }

    func glyphQuads(_ n: EvalNode, mvp: simd_float4x4, pxScale: Float) -> [GlyphQuad] {
        let l = layout(n)
        guard !l.glyphs.isEmpty else { return [] }
        let size = n.num("size", 100)
        let color = textColor(n)

        // Kinetic reveal: {"by":"word","stagger":0.05,"duration":0.6,"delay":0,"ease":"outExpo",
        //                  "from":{"opacity":0,"y":40,"x":0,"scale":1,"rotation":0},"mask":true,"order":"forward"}
        let rv = n.props["reveal"]?.object
        let mode = rv?["by"]?.string ?? "char"
        let stagger = rv?["stagger"]?.double ?? 0.03, dur = max(rv?["duration"]?.double ?? 0.6, 1e-3)
        let delay = rv?["delay"]?.double ?? 0
        let ease = (try? rv?["ease"].map(Easing.init(json:))) ?? Easing("outExpo")
        let from = rv?["from"]?.object ?? ["opacity": 0, "y": .number(size * 0.4)]
        let mask = rv?["mask"]?.bool ?? false
        let order = rv?["order"]?.string ?? "forward"
        let count = l.unitCount[mode] ?? 1
        let big: Float = 1e7

        var out: [GlyphQuad] = []
        for g in l.glyphs {
            guard let e = glyphs.get(font: g.font, glyph: g.glyph, pixelScale: CGFloat(pxScale)) else { continue }
            var unitM = matrix_identity_float4x4
            var unitAlpha = 1.0
            if rv != nil {
                let idx = l.unit(g, mode)
                let k: Double
                switch order {
                case "reverse": k = Double(count - 1 - idx)
                case "center": k = abs(Double(idx) - Double(count - 1) / 2)
                case "random": k = floor(InstanceLayout.rand(Double(idx)) * Double(count))
                default: k = Double(idx)
                }
                let p = ease.apply((n.t - delay - k * stagger) / dur)
                let q = 1 - p
                func fv(_ key: String, _ d: Double) -> Double { from[key]?.double ?? d }
                unitAlpha = fv("opacity", 1) + (1 - fv("opacity", 1)) * p
                let c = l.unitCenter[mode]?[idx] ?? CGPoint(x: g.x, y: g.baseline)
                let s = Float(fv("scale", 1) + (1 - fv("scale", 1)) * p)
                // skew: degrees of slant (positive leans the top to the right), easing back to upright.
                var shear = matrix_identity_float4x4
                shear.columns.1.x = -tan(Float(fv("skew", 0) * q) * .pi / 180)
                unitM =
                    M.translate(Float(fv("x", 0) * q) + Float(c.x), Float(fv("y", 0) * q) + Float(c.y), 0)
                    * M.rotateZ(Float(fv("rotation", 0) * q) * .pi / 180)
                    * shear
                    * M.scale(s, s, 1)
                    * M.translate(-Float(c.x), -Float(c.y), 0)
            }
            let alpha = n.opacity * unitAlpha
            guard alpha > 0.0001 else { continue }
            let rect = SIMD4<Float>(
                Float(g.x + e.ox / e.scale), Float(g.baseline - (e.oy + CGFloat(e.h)) / e.scale),
                Float(CGFloat(e.w) / e.scale), Float(CGFloat(e.h) / e.scale))
            let line = l.lines[g.line]
            let clip = mask ? SIMD4<Float>(-big, Float(line.top), big, Float(line.bottom)) : TexU.noClip
            let u = TexU(
                mvp: mvp, unit: unitM, rect: rect, color: color.linearPremultiplied(opacity: alpha), clip: clip,
                mode: .zero)
            out.append(GlyphQuad(u: u, texture: e.texture, unitAlpha: unitAlpha))
        }
        return out
    }
}
