import Foundation
import Metal
import simd

/// World-pass drawing phases. Every 3D node is visited once per phase so that ground planes and
/// light pools always sit under anything standing on them, whatever the node order.
enum WorldPhase: Int, CaseIterable { case ground, pools, shadows, objects, beams }

extension Renderer {
    /// Draws one phase of a repeater (crowd of sprites standing on its local xz plane) or a `light`.
    func drawInstancer(
        _ n: EvalNode, phase: WorldPhase, cam: CameraState, scene: Scene, T: Double, scale: Double, assets: URL?,
        enc: MTLRenderCommandEncoder
    ) {
        let isLight = n.node.type == "light"
        var items: [[String: JSONValue]] =
            n.props["items"]?.array?.compactMap(\.object) ?? n.props["item"]?.object.map { [$0] } ?? []
        if items.isEmpty && !isLight { items = [["symbol": "basic/dot", "height": 40]] }
        let instances: [Instance]
        if let c = frameInstances[n.node.id] {
            instances = c
        } else {
            instances =
                isLight
                ? [Instance(pos: .zero, lit: 1)]
                : InstanceLayout.build(n, items: items, evaluator: evaluator, T: T, duration: scene.duration)
            frameInstances[n.node.id] = instances
        }
        guard !instances.isEmpty else { return }

        let Mw = n.world
        func dir(_ v: SIMD3<Float>) -> SIMD3<Float> { let r = Mw * SIMD4(v, 0); return SIMD3(r.x, r.y, r.z) }
        func pt(_ v: SIMD3<Float>) -> SIMD3<Float> { let r = Mw * SIMD4(v, 1); return SIMD3(r.x, r.y, r.z) }
        let ax = dir(SIMD3(1, 0, 0)), up = dir(SIMD3(0, -1, 0)), az = dir(SIMD3(0, 0, 1))
        let upN = simd_normalize(up)
        let unitScale = simd_length(ax)
        var vp = cam.viewProj
        let world = instances.map { pt($0.pos) }
        let depths = world.map { cam.depth($0) }

        // Billboard right vector: camera right flattened against the sprite's up axis.
        var bill = cam.right - simd_dot(cam.right, upN) * upN
        bill = simd_length(bill) < 1e-4 ? simd_normalize(ax) : simd_normalize(bill)

        switch phase {
        case .ground:
            guard !isLight, let gp = n.props["ground"], gp.bool != false else { return }  // floor only when asked for
            let g = n.props["ground"]?.object ?? [:]
            let xs = instances.map(\.pos.x), zs = instances.map(\.pos.z)
            let margin = Float(items.first?["height"]?.double ?? 100) * 3
            let size =
                g["size"]?.doubles.map { SIMD2(Float($0[0]), Float($0.count > 1 ? $0[1] : $0[0])) }
                ?? SIMD2((xs.max()! - xs.min()!) + margin * 2, (zs.max()! - zs.min()!) + margin * 2)
            let center = SIMD3((xs.max()! + xs.min()!) / 2, 0, (zs.max()! + zs.min()!) / 2)
            let color = (RGBA.parse(g["color"]) ?? RGBA(0.035, 0.035, 0.035)).linearPremultiplied(opacity: n.opacity)
            // Checkerboard: {"size": cell (default = grid spacing), "color", "opacity"}; cells centred on grid positions.
            var checker = SIMD4<Float>.zero, checkerColor = SIMD4<Float>.zero
            if let ck = g["checker"], ck.bool != false {
                let o = ck.object ?? [:]
                let sp: Double = n.props["spacing"]?.doubles?.first ?? n.props["spacing"]?.double ?? 100
                let s = Float(o["size"]?.double ?? sp)
                let grid = n.str("layout", "grid") == "grid"
                let x0 = grid ? xs.min()! : 0, z0 = grid ? zs.min()! : 0
                checker = SIMD4(s, center.x - x0 + s / 2, center.z - z0 + s / 2, 0)
                checkerColor = (RGBA.parse(o["color"]) ?? RGBA(0.925, 0.906, 0.863))
                    .linearPremultiplied(opacity: (o["opacity"]?.double ?? 0.045) * n.opacity)
            }
            drawShapeRaw(
                mvp: cam.viewProj * Mw * M.translate(center.x, center.y, center.z) * M.rotateX(.pi / 2),
                fill: color, size: size, aaPad: 0, enc: enc
            ) { u in
                u.checker = checker; u.checkerColor = checkerColor
            }

        case .pools:
            let itemH = items.map { $0["height"]?.double ?? 100 }.max() ?? 100
            // Ambient wash under the crowd that grows with the share of lit instances:
            // {"radius", "intensity": 0.035, "grow": 0.07, "color", "center": [x, z]}.
            if !isLight, let amb = n.props["ambient"]?.object {
                let xs = instances.map(\.pos.x), zs = instances.map(\.pos.z)
                let c =
                    amb["center"]?.doubles.map { SIMD3(Float($0[0]), 0, Float($0.count > 1 ? $0[1] : 0)) }
                    ?? SIMD3((xs.max()! + xs.min()!) / 2, 0, (zs.max()! + zs.min()!) / 2)
                let frac = instances.reduce(Float(0)) { $0 + min($1.lit, 1) } / Float(instances.count)
                let k = Float(amb["intensity"]?.double ?? 0.035) + Float(amb["grow"]?.double ?? 0.07) * frac
                let r = Float(amb["radius"]?.double ?? Double(max(xs.max()! - xs.min()!, zs.max()! - zs.min()!) * 0.6))
                let col = (RGBA.parse(amb["color"]) ?? RGBA(0.925, 0.906, 0.863)).linearPremultiplied()
                let q = [
                    QuadI(
                        pos: SIMD4(pt(c), 0), a: SIMD4(ax * r, 0), b: SIMD4(az * r, 0), uv: SIMD4(1, 1, 0, 0),
                        color: light(col, k, alpha: min(1, k)) * Float(n.opacity))
                ]
                drawQuads(q, pso: poolPSO, decal: true, vp: &vp, texture: nil, enc: enc)
            }
            guard let pool = n.props["pool"]?.object ?? (isLight ? [:] : nil) else { return }
            let defaultR = isLight ? 150.0 : itemH * 0.55
            let r = Float(pool["radius"]?.double ?? defaultR)
            let col = (RGBA.parse(pool["color"]) ?? RGBA(1, 1, 1)).linearPremultiplied()
            let intensity = Float(pool["intensity"]?.double ?? 1.2)
            let soft = Float(pool["softness"]?.double ?? 0.5), falloff = Float(pool["falloff"]?.double ?? 1)
            // Spill: a wide faint glow around each pool that lifts neighbouring silhouettes. {"radius": x pool radius, "intensity"}
            let spill = pool["spill"]?.object
            let spillR = Float(spill?["radius"]?.double ?? 3), spillK = Float(spill?["intensity"]?.double ?? 0.16)
            var quads: [QuadI] = [], spills: [QuadI] = []
            for (i, inst) in instances.enumerated() where inst.lit > 0.001 && depths[i] > cam.near {
                let k = inst.lit * intensity * inst.opacity * Float(n.opacity)
                let rr = r * inst.scale
                quads.append(
                    QuadI(
                        pos: SIMD4(world[i], 0), a: SIMD4(ax * rr, 0), b: SIMD4(az * rr, 0),
                        uv: SIMD4(soft, falloff, 0, 0), color: light(col, k, alpha: min(1, k))))
                if spill != nil {
                    let ks = inst.lit * spillK * inst.opacity * Float(n.opacity)
                    spills.append(
                        QuadI(
                            pos: SIMD4(world[i], 0), a: SIMD4(ax * rr * spillR, 0), b: SIMD4(az * rr * spillR, 0),
                            uv: SIMD4(1, 1.5, 0, 0), color: light(col, ks, alpha: min(1, ks))))
                }
            }
            drawQuads(spills, pso: poolPSO, decal: true, vp: &vp, texture: nil, enc: enc)
            drawQuads(quads, pso: poolPSO, decal: true, vp: &vp, texture: nil, enc: enc)

        case .shadows, .objects:
            guard !isLight,
                let atlas = atlas(
                    items: items, instances: instances, depths: depths, unitScale: unitScale,
                    cam: cam, scale: scale, assets: assets)
            else { return }
            let facingCamera = n.str("facing", "camera") == "camera"
            func edges(_ i: Int) -> (cell: SpriteAtlas.Cell, right: SIMD3<Float>, upV: SIMD3<Float>) {
                let inst = instances[i]
                let cell = atlas.cell(for: inst)
                let h = cell.height * inst.scale
                var r = bill
                if !facingCamera {
                    let yaw = inst.yaw * .pi / 180
                    r = simd_normalize(ax * cos(yaw) + az * sin(yaw))
                }
                return (cell, r * h * cell.aspect * unitScale, up * h)
            }
            let order = instances.indices.filter { depths[$0] > cam.near && instances[$0].opacity > 0.001 }.sorted {
                depths[$0] > depths[$1]
            }

            if phase == .shadows {
                // Contact shadows: a dark disc under every instance (light from straight above).
                // {"radius": fraction of item height (0.17), "opacity": 0.85, "softness": 0.3}
                if let ct = n.props["contact"]?.object {
                    let op = Float(ct["opacity"]?.double ?? 0.85), soft = Float(ct["softness"]?.double ?? 0.3)
                    let rf = Float(ct["radius"]?.double ?? 0.17)
                    var discs: [QuadI] = []
                    for i in order {
                        let inst = instances[i], cell = atlas.cell(for: inst)
                        let rr = rf * cell.height * inst.scale * unitScale
                        let a = op * inst.opacity * Float(n.opacity)
                        discs.append(
                            QuadI(
                                pos: SIMD4(world[i], 0), a: SIMD4(simd_normalize(ax) * rr, 0),
                                b: SIMD4(simd_normalize(az) * rr, 0),
                                uv: SIMD4(soft, 0, 0, 0), color: SIMD4(0, 0, 0, a)))
                    }
                    drawQuads(discs, pso: contactPSO, decal: true, vp: &vp, texture: nil, enc: enc)
                }
                // The sprite laid flat on the ground, pointing away from the light.
                guard let sh = n.props["shadow"]?.object else { return }
                let opacity = Float(sh["opacity"]?.double ?? 0.6), len = Float(sh["length"]?.double ?? 1)
                let ang = Float(sh["angle"]?.double ?? 0) * .pi / 180
                let gdir = simd_normalize(az * cos(ang) + ax * sin(ang)) * simd_length(up)
                let litOnly = sh["litOnly"]?.bool ?? true
                var quads: [QuadI] = []
                for i in order {
                    let e = edges(i), inst = instances[i]
                    let a = opacity * inst.opacity * Float(n.opacity) * (litOnly ? min(inst.lit, 1) : 1)
                    guard a > 0.001 else { continue }
                    quads.append(
                        QuadI(
                            pos: SIMD4(world[i], 0), a: SIMD4(e.right, 0),
                            b: SIMD4(gdir * e.cell.height * inst.scale * len, 0),
                            uv: e.cell.uv, color: SIMD4(0, 0, 0, a)))
                }
                drawQuads(quads, pso: shadowPSO, decal: false, vp: &vp, texture: atlas.texture, enc: enc)
            } else {
                if let cone = n.props["cone"]?.object {
                    drawCones(
                        cone, n: n, instances: instances, world: world, depths: depths, order: order, atlas: atlas,
                        up: up, ax: ax, az: az, cam: cam, enc: enc)
                }
                // Sprites, far to near. pos.w carries the rim-light amount for lit instances.
                let baseColor = n.color("color") ?? foreground
                // Rim: drawn edge highlights for vector items (default 0.8), a soft top glow otherwise (0.12).
                let rimProp = n.props["rim"]?.double
                let rimColor = (n.color("rimColor") ?? RGBA.parse(evaluator.resolve("$fg")) ?? RGBA(0.95, 0.93, 0.88))
                    .linearPremultiplied()
                var quads: [QuadI] = []
                quads.reserveCapacity(order.count)
                for i in order {
                    let e = edges(i), inst = instances[i]
                    let c = (inst.color ?? baseColor).linearPremultiplied(opacity: Double(inst.opacity) * n.opacity)
                    let rim = Float(rimProp ?? (e.cell.rimOffset > 0 ? 0.8 : 0.12))
                    quads.append(
                        QuadI(
                            pos: SIMD4(world[i], min(inst.lit, 1) * rim), a: SIMD4(e.right, 0), b: SIMD4(e.upV, 0),
                            uv: e.cell.uv, color: c, extra: SIMD4(rimColor.x, rimColor.y, rimColor.z, e.cell.rimOffset))
                    )
                }
                drawQuads(quads, pso: spritePSO, decal: false, vp: &vp, texture: atlas.texture, enc: enc)
            }

        case .beams:
            guard let beam = n.props["beam"]?.object else { return }
            let h = Float(beam["height"]?.double ?? 900), w = Float(beam["width"]?.double ?? 160)
            let intensity = Float(beam["intensity"]?.double ?? 0.12)
            let col = (RGBA.parse(beam["color"]) ?? RGBA(1, 1, 1)).linearPremultiplied()
            var quads: [QuadI] = []
            for (i, inst) in instances.enumerated() where inst.lit > 0.001 && depths[i] > cam.near {
                let k = inst.lit * intensity * inst.opacity * Float(n.opacity)
                quads.append(
                    QuadI(
                        pos: SIMD4(world[i], 0), a: SIMD4(bill * w * unitScale * inst.scale, 0), b: SIMD4(up * h, 0),
                        uv: .zero, color: light(col, k, alpha: 0)))
            }
            drawQuads(quads, pso: beamPSO, decal: false, vp: &vp, texture: nil, enc: enc)
        }
    }

    /// Sprite atlas sized for the largest on-screen sprite (power of two, 64...1024 px tall).
    private func atlas(
        items: [[String: JSONValue]], instances: [Instance], depths: [Float], unitScale: Float,
        cam: CameraState, scale: Double, assets: URL?
    ) -> SpriteAtlas? {
        guard !items.isEmpty else { return nil }
        let maxH = items.map { Float($0["height"]?.double ?? 100) }.max() ?? 100
        let maxScale = instances.map(\.scale).max() ?? 1
        let nearest = max(depths.filter { $0 > cam.near }.min() ?? 1000, cam.near)
        let px = maxH * maxScale * unitScale * cam.focalPx / nearest * Float(scale)
        let R = max(64, min(1024, 1 << Int(ceil(log2(max(px * 1.2, 1))))))
        // Symbols and images can be rewritten on disk (symbol_save, asset_write), and the same items can mean other
        // art in another project: the key has the project's symbol stamp and each image's date.
        let images = items.compactMap { $0["src"]?.string }.map {
            SymbolRasterCache.fileDate(AssetPath.url($0, assets: assets))
        }
        let files = SymbolRasterCache.stamp(project: assets?.deletingLastPathComponent())
        let content = items.map { compactKey($0) }.joined(separator: ";")
        let key = "\(R)|\(files)|\(images.joined(separator: ","))|\(content)"
        if let a = atlases[key] { return a }
        let a = SpriteAtlas.build(items: items, rasterHeight: R, device: device, queue: queue, assets: assets)
        if atlases.count > 32 { atlases.removeAll() }
        atlases[key] = a
        return a
    }

    func drawQuads(
        _ quads: [QuadI], pso: MTLRenderPipelineState, decal: Bool, vp: inout simd_float4x4,
        texture: MTLTexture?, enc: MTLRenderCommandEncoder
    ) {
        guard !quads.isEmpty else { return }
        let bytes = quads.count * MemoryLayout<QuadI>.stride
        enc.setRenderPipelineState(pso)
        if bytes <= 4096 {
            quads.withUnsafeBytes { enc.setVertexBytes($0.baseAddress!, length: bytes, index: 0) }
        } else {
            guard
                let buf = quads.withUnsafeBytes({
                    device.makeBuffer(bytes: $0.baseAddress!, length: bytes, options: .storageModeShared)
                })
            else { return }
            enc.setVertexBuffer(buf, offset: 0, index: 0)
        }
        enc.setVertexBytes(&vp, length: MemoryLayout<simd_float4x4>.stride, index: 2)
        if let texture { enc.setFragmentTexture(texture, index: 0) }
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: quads.count)
    }

    /// A light's premultiplied colour: `c` scaled by `k`, with its own alpha.
    private func light(_ c: SIMD4<Float>, _ k: Float, alpha: Float) -> SIMD4<Float> {
        SIMD4(c.x * k, c.y * k, c.z * k, alpha)
    }

    func compactKey(_ o: [String: JSONValue]) -> String {
        o.keys.sorted().map { "\($0)=\(o[$0]!.string ?? "\(o[$0]!)")" }.joined(separator: ",")
    }
}
