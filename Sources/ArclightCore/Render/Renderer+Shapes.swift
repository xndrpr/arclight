import Metal
import simd

extension Renderer {
    /// A line shape's end point relative to its start (`to`, default [100, 0]).
    func lineEnd(_ n: EvalNode) -> (dx: Double, dy: Double) {
        let to = n.props["to"]?.doubles ?? [100, 0]
        return (to.first ?? 100, to.count > 1 ? to[1] : 0)
    }

    func drawShape(_ n: EvalNode, mvp: simd_float4x4, pxScale: Float, enc: MTLRenderCommandEncoder) {
        let kind = n.str("shape", "rect")
        let fg = foreground
        let aaPad = 2 / max(pxScale, 1e-3)
        var m = mvp, w: Float, h: Float, radius: Float, sw: Float
        var fill: RGBA, stroke: RGBA? = nil, k: Float = 0

        if kind == "line" {
            let end = lineEnd(n)
            let dx = Float(end.dx), dy = Float(end.dy)
            let len = sqrt(dx * dx + dy * dy)
            let trim = n.props["trim"]?.doubles ?? [0, 1]
            let a = Float(trim.first ?? 0), b = Float(trim.count > 1 ? trim[1] : 1)
            guard b > a, len > 0 else { return }
            sw = Float(n.num("strokeWidth", 4))
            let round = n.str("cap", "butt") == "round"
            let seg = len * (b - a)
            w = seg + (round ? sw : 0); h = sw; radius = round ? sw / 2 : 0
            m = mvp * M.rotateZ(atan2(dy, dx)) * M.translate(len * (a + b) / 2, 0, 0)
            fill = n.color("stroke") ?? n.color("fill") ?? fg
            sw = 0
        } else {
            w = Float(n.num("width", 100)); h = Float(n.num("height", kind == "ellipse" ? Double(w) : 100))
            radius = Float(n.num("radius", 0)); sw = Float(n.num("strokeWidth", 0))
            stroke = n.color("stroke")
            let isGradient = n.props["fill"]?.object?["stops"] != nil
            fill = n.color("fill") ?? (isGradient || (stroke != nil && sw > 0) ? RGBA(0, 0, 0, 0) : fg)
            k = kind == "ellipse" ? 1 : 0
        }
        let gradient = kind == "line" ? nil : GradientFill(n.props["fill"], opacity: n.opacity)
        drawShapeRaw(
            mvp: m, fill: fill.linearPremultiplied(opacity: n.opacity),
            stroke: (stroke ?? RGBA(0, 0, 0, 0)).linearPremultiplied(opacity: n.opacity),
            size: SIMD2(w, h), radius: radius, strokeWidth: sw, ellipse: k > 0, aaPad: aaPad, enc: enc
        ) { u in
            gradient?.apply(&u)
        }
    }

    func drawShapeRaw(
        mvp: simd_float4x4, fill: SIMD4<Float>, stroke: SIMD4<Float> = .zero, size: SIMD2<Float>, radius: Float = 0,
        strokeWidth: Float = 0, ellipse: Bool = false, aaPad: Float, enc: MTLRenderCommandEncoder,
        configure: ((inout ShapeU) -> Void)? = nil
    ) {
        var u = ShapeU(
            mvp: mvp, fill: fill, stroke: stroke, geom: SIMD4(size.x, size.y, radius, strokeWidth),
            extra: SIMD4(ellipse ? 1 : 0, aaPad, 0, 0))
        configure?(&u)
        enc.setRenderPipelineState(shapePSO)
        enc.setVertexBytes(&u, length: MemoryLayout<ShapeU>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<ShapeU>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
