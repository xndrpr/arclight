import Foundation
import Metal
import simd

extension Renderer {
    /// Encodes a frame into `output` (bgra8Unorm_srgb). Used by preview, export and the editor viewport.
    public func encode(
        scene: Scene, project: Project, assets: URL?, time T: Double, scale: Double, transparent: Bool,
        commandBuffer cb: MTLCommandBuffer, targets t: RenderTargets, output: MTLTexture
    ) {
        evaluator.theme = scene.theme(over: project.theme)
        currentAssets = assets
        let (cw, ch) = project.size(for: scene)
        let W = Float(cw), H = Float(ch)
        let fps = scene.fps ?? project.fps
        let nodes = drawable(evaluator.evaluate(scene, T: T), scene)
        let overlay = nodes.filter { !$0.is3D }
        let post = evaluator.sceneValue(scene.post, scene, T: T)?.object ?? [:]

        // With motion blur the world is rendered at several sub-frame times across the shutter and averaged;
        // the 2D overlay stays sharp.
        var cur: MTLTexture
        let mb = post["motionBlur"]
        let samples = draft ? 1 : max(1, min(16, Int(mb?.double ?? mb?["samples"]?.double ?? 1)))
        if samples > 1 {
            let shutter = mb?["shutter"]?.double ?? 0.5  // fraction of a frame (0.5 = 180°)
            var w = SIMD4<Float>(1 / Float(samples), 0, 0, 0)
            for i in 0..<samples {
                let ti = max(0, T + (Double(i) / Double(samples - 1) - 0.5) * shutter / fps)
                let sceneNodes = i == samples / 2 ? nodes : drawable(evaluator.evaluate(scene, T: ti), scene)
                let src = renderWorld(
                    scene: scene, nodes: sceneNodes.filter(\.is3D), T: ti, W: W, H: H, scale: scale,
                    transparent: transparent, assets: assets, cb: cb, t: t)
                fullscreen(
                    cb, target: t.accum, pso: scalePSO, textures: [src], params: &w, loadAction: i == 0 ? .clear : .load
                )
            }
            cur = t.accum
        } else {
            cur = renderWorld(
                scene: scene, nodes: nodes.filter(\.is3D), T: T, W: W, H: H, scale: scale,
                transparent: transparent, assets: assets, cb: cb, t: t)
        }

        // The 2D overlay goes into its own layer, composited after grading (see final_fs).
        let ovTarget = cur === t.hdrA ? t.hdrB : t.hdrA
        var ou = FrameU()
        func overlayPass(clear: Bool) -> MTLRenderCommandEncoder? {
            let enc = pass(cb, color: ovTarget, clear: clear ? .zero : nil, coc: t.coc, clearCoc: false)
            enc?.setFragmentSamplerState(sampler, index: 0)
            enc?.setFragmentBytes(&ou, length: MemoryLayout<FrameU>.stride, index: 1)
            return enc
        }
        var enc = overlayPass(clear: true)
        let proj = M.ortho(width: W, height: H)
        // Layers with effects (and the layers that clip layers rest on) are drawn alone and composited; mask layers
        // are only drawn as masks.
        let (maskIds, clipBases) = Renderer.maskAndClipBases(overlay)
        let byId = Dictionary(overlay.map { ($0.node.id, $0) }, uniquingKeysWith: { a, _ in a })
        var hasBase = false
        for n in overlay {
            guard let e = enc else { break }
            if maskIds.contains(n.node.id) { continue }
            let isBase = clipBases.contains(n.node.id)
            let clips = n.props["clip"]?.bool == true && hasBase
            if isBase || clips || Renderer.needsEffects(n) {
                e.endEncoding()
                let fxT = try? fx.targets(device: device, width: t.width, height: t.height)
                drawWithEffects(
                    n, proj: proj, scale: scale, assets: assets, cb: cb, t: t, target: ovTarget, world: cur,
                    clipBase: clips ? fxT?.base : nil,
                    maskNode: n.props["mask"]?["node"]?.string.flatMap { byId[$0] })
                if isBase, let x = fxT { blit(cb, from: x.comp, to: x.base); hasBase = true }
                enc = overlayPass(clear: false)
                continue
            }
            if n.props["clip"]?.bool != true { hasBase = false }
            let mvp = proj * n.world
            let px = Float(scale) * M.maxScale(n.world)
            // Text whose glyphs touch sums their coverage in passes of its own (no seam at the joints).
            if n.node.type == "text" && glyphsTouch(n, pxScale: px) {
                e.endEncoding()
                drawTextUnion(n, mvp: mvp, pxScale: px, cb: cb, t: t, target: ovTarget)
                enc = overlayPass(clear: false)
                continue
            }
            switch n.node.type {
            case "shape": drawShape(n, mvp: mvp, pxScale: px, enc: e)
            case "text": drawText(n, mvp: mvp, pxScale: px, enc: e)
            case "image": drawImage(n, mvp: mvp, assets: assets, enc: e)
            case "symbol": drawSymbol(n, mvp: mvp, pxScale: px, assets: assets, enc: e)
            default: break
            }
        }
        enc?.endEncoding()

        // Bloom (from world and overlay), then the final grade.
        let bloomIntensity = encodeBloom(post["bloom"], source: cur, overlay: ovTarget, cb: cb, t: t)
        var pu = grade(post, scene: scene, T: T, fps: fps, aspect: W / H, bloomIntensity: bloomIntensity)
        fullscreen(cb, target: output, pso: finalPSO, textures: [cur, t.bloom[0], ovTarget], params: &pu)
    }

    /// World pass (+ depth of field) at time T. Returns the texture holding the result (hdrA or hdrB).
    func renderWorld(
        scene: Scene, nodes world: [EvalNode], T: Double, W: Float, H: Float, scale: Double, transparent: Bool,
        assets: URL?, cb: MTLCommandBuffer, t: RenderTargets
    ) -> MTLTexture {
        let cam = CameraState.make(evaluator.sceneValue(scene.camera, scene, T: T), width: W, height: H, time: T)
        let fog = evaluator.sceneValue(scene.fog, scene, T: T)?.object
        let bg = transparent ? SIMD4<Float>(0, 0, 0, 0) : evaluator.background(scene, T: T).linearPremultiplied()
        let dofOn = cam.blur > 0 && !world.isEmpty

        var fu = FrameU()
        fu.dof = SIMD4(cam.blur, cam.focus, cam.range, dofOn ? 1 : 0)
        if let fog {
            fu.fogColor = (RGBA.parse(fog["color"]) ?? evaluator.background(scene, T: T)).linearPremultiplied()
            fu.fog = SIMD4(Float(fog["near"]?.double ?? 1000), Float(fog["far"]?.double ?? 5000), 1, 0)
        }

        // View depth -> window depth (the projection in CameraState.make), for the depth step's push.
        let span = max(cam.far - cam.near, 1e-3)
        fu.misc = SIMD4(cam.far / span, cam.near * cam.far / span, Renderer.coplanarPush, 0)

        if let enc = pass(cb, color: t.hdrA, clear: bg, coc: t.coc, clearCoc: true, depth: t.depth) {
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.setFragmentBytes(&fu, length: MemoryLayout<FrameU>.stride, index: 1)
            enc.setDepthStencilState(depthTest)
            frameInstances.removeAll(keepingCapacity: true)
            let instancers = world.filter { $0.node.type == "repeater" || $0.node.type == "light" }
            let models = world.filter { $0.node.type == "model" }
            let cards = world.filter { !["repeater", "light", "model"].contains($0.node.type) }
            for phase in WorldPhase.allCases {
                // Cards (flat 3D layers) go first in the objects phase, in list order: each is drawn depth-tested,
                // then writes its depth where it is solid, so a layer behind it that comes later stays hidden. The
                // repeater sprites and light beams after them are tested against that depth.
                if phase == .objects {
                    // Models are solid: drawn first, they hide what's behind them from every card after.
                    for n in models { drawModel(n, cam: cam, assets: assets, enc: enc) }
                    for n in cards { drawCard(n, cam: cam, scale: scale, assets: assets, enc: enc) }
                }
                for n in instancers {
                    drawInstancer(n, phase: phase, cam: cam, scene: scene, T: T, scale: scale, assets: assets, enc: enc)
                }
            }
            enc.endEncoding()
        }

        if dofOn {
            var p = SIMD4<Float>(Float(scale), cam.blur * Float(scale), 1 / Float(t.width), 1 / Float(t.height))
            fullscreen(cb, target: t.hdrB, pso: dofPSO, textures: [t.hdrA, t.coc], params: &p)
            return t.hdrB
        }
        return t.hdrA
    }

    func pass(
        _ cb: MTLCommandBuffer, color: MTLTexture, clear: SIMD4<Float>?, coc: MTLTexture, clearCoc: Bool,
        depth: MTLTexture? = nil
    ) -> MTLRenderCommandEncoder? {
        let rp = MTLRenderPassDescriptor()
        if let depth {
            rp.depthAttachment.texture = depth
            rp.depthAttachment.loadAction = .clear
            rp.depthAttachment.clearDepth = 1
            rp.depthAttachment.storeAction = .dontCare
        }
        rp.colorAttachments[0].texture = color
        if let c = clear {
            rp.colorAttachments[0].loadAction = .clear
            rp.colorAttachments[0].clearColor = MTLClearColor(
                red: Double(c.x), green: Double(c.y), blue: Double(c.z), alpha: Double(c.w))
        } else {
            rp.colorAttachments[0].loadAction = .load
        }
        rp.colorAttachments[0].storeAction = .store
        rp.colorAttachments[1].texture = coc
        rp.colorAttachments[1].loadAction = clearCoc ? .clear : .dontCare
        rp.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[1].storeAction = clearCoc ? .store : .dontCare
        return cb.makeRenderCommandEncoder(descriptor: rp)
    }

    func fullscreen<P>(
        _ cb: MTLCommandBuffer, target: MTLTexture, pso: MTLRenderPipelineState, textures: [MTLTexture],
        params: inout P, loadAction: MTLLoadAction = .dontCare, scissor: MTLScissorRect? = nil
    ) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = target
        rp.colorAttachments[0].loadAction = loadAction
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pso)
        // Effects limit their passes to the layer's area (the rest of a cleared target stays clear).
        if let scissor { enc.setScissorRect(scissor) }
        for (i, tx) in textures.enumerated() { enc.setFragmentTexture(tx, index: i) }
        enc.setFragmentSamplerState(sampler, index: 0)
        withUnsafeBytes(of: &params) { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    /// How far a 3D card's written depth is pushed back, as a fraction of its view depth (0.05 % = 1 px at 2000 px):
    /// layers stacked on one plane, or within that distance in front of it, draw over it in list order.
    static let coplanarPush: Float = 0.0005

    /// One flat 3D layer in the world pass: colour (depth-tested), then its depth where it is at least half covered.
    func drawCard(_ n: EvalNode, cam: CameraState, scale: Double, assets: URL?, enc: MTLRenderCommandEncoder) {
        let mvp = cam.viewProj * n.world
        let px = pxScale(n, cam: cam, scale: scale)
        defer { worldStage = .off }
        for stage in [WorldStage.color, .depth] {
            worldStage = stage
            enc.setDepthStencilState(stage == .depth ? depthWrite : depthTest)
            switch n.node.type {
            case "shape": drawShape(n, mvp: mvp, pxScale: px, enc: enc)
            case "text": drawText(n, mvp: mvp, pxScale: px, enc: enc)
            case "image": drawImage(n, mvp: mvp, assets: assets, enc: enc)
            case "symbol": drawSymbol(n, mvp: mvp, pxScale: px, assets: assets, enc: enc)
            case "box": drawBox(n, cam: cam, assets: assets, enc: enc)
            default: break
            }
        }
        enc.setDepthStencilState(depthTest)
    }

    /// Output pixels per node unit, including perspective for 3D nodes (picks raster resolution for text, AA width for shapes).
    func pxScale(_ n: EvalNode, cam: CameraState, scale: Double) -> Float {
        let c = n.world.columns.3
        let depth = max(cam.depth(SIMD3(c.x, c.y, c.z)), cam.near)
        return Float(scale) * M.maxScale(n.world) * cam.focalPx / depth
    }
}
