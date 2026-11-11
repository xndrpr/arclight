import Metal
import simd

extension Renderer {
    /// Light cones: for each lit instance, the screen-space convex hull of a lamp point above it and
    /// its pool circle, filled with a gradient from 0 at the lamp to 0.14 at the pool, additive.
    /// {"height": x item height (5.4), "radius": world units (default = pool radius), "intensity": 1, "color"}
    func drawCones(
        _ cone: [String: JSONValue], n: EvalNode, instances: [Instance], world: [SIMD3<Float>], depths: [Float],
        order: [Int], atlas: SpriteAtlas, up: SIMD3<Float>, ax: SIMD3<Float>, az: SIMD3<Float>,
        cam: CameraState, enc: MTLRenderCommandEncoder
    ) {
        let hMul = Float(cone["height"]?.double ?? 5.4)
        let poolR = n.props["pool"]?.object?["radius"]?.double
        let intensity = Float(cone["intensity"]?.double ?? 1)
        let col = (RGBA.parse(cone["color"]) ?? RGBA(0.925, 0.906, 0.863)).linearPremultiplied()
        var verts: [ConeV] = []
        func project(_ p: SIMD3<Float>) -> SIMD2<Float>? {
            let c = cam.viewProj * SIMD4(p, 1)
            guard c.w > cam.near else { return nil }
            return SIMD2(c.x / c.w, c.y / c.w)
        }
        // Hull in NDC; the gradient is measured in pixel-proportional space (x scaled by aspect).
        func px(_ v: SIMD2<Float>) -> SIMD2<Float> { SIMD2(v.x * cam.aspect, v.y) }
        for i in order where instances[i].lit > 0.001 {
            let inst = instances[i], cell = atlas.cell(for: inst)
            let r = Float(cone["radius"]?.double ?? poolR ?? Double(cell.height * 0.55)) * inst.scale
            guard let apex = project(world[i] + up * cell.height * inst.scale * hMul) else { continue }
            var ring: [SIMD2<Float>] = []
            for k in 0..<14 {
                let a = Float(k) / 14 * 2 * .pi
                guard let q = project(world[i] + ax * r * cos(a) + az * r * sin(a)) else { ring.removeAll(); break }
                ring.append(q)
            }
            guard ring.count == 14 else { continue }
            let hull = convexHull([apex] + ring)
            guard hull.count >= 3 else { continue }
            let centre = ring.reduce(SIMD2<Float>.zero, +) / Float(ring.count)
            let S = px(apex), C = px(centre), d = C - S
            let dd = max(simd_dot(d, d), 1e-8)
            let k = intensity * min(inst.lit, 1.5) * inst.opacity * Float(n.opacity)
            let color = SIMD4(col.x, col.y, col.z, k)
            func v(_ p: SIMD2<Float>) -> ConeV {
                ConeV(pos: SIMD4(p.x, p.y, simd_dot(px(p) - S, d) / dd, depths[i]), color: color)
            }
            for j in 1..<(hull.count - 1) { verts += [v(hull[0]), v(hull[j]), v(hull[j + 1])] }
        }
        guard !verts.isEmpty else { return }
        let bytes = verts.count * MemoryLayout<ConeV>.stride
        guard
            let buf = verts.withUnsafeBytes({
                device.makeBuffer(bytes: $0.baseAddress!, length: bytes, options: .storageModeShared)
            })
        else { return }
        enc.setRenderPipelineState(conePSO)
        enc.setVertexBuffer(buf, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
    }

    /// Andrew's monotone chain.
    func convexHull(_ pts: [SIMD2<Float>]) -> [SIMD2<Float>] {
        let p = pts.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard p.count > 2 else { return p }
        func cross(_ o: SIMD2<Float>, _ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Float>] = [], upper: [SIMD2<Float>] = []
        for q in p {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 {
                lower.removeLast()
            }; lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 {
                upper.removeLast()
            }; upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }
}
