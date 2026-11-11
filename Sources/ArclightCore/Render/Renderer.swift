import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Metal
import MetalKit
import simd

/// Renders scenes with Metal.
///
/// Frame structure:
/// 1. World pass — 3D nodes (camera, fog) into color + circle-of-confusion targets.
/// 2. Depth of field — when the camera has `dof.blur`.
/// 3. Overlay pass — 2D nodes on top, in list order.
/// 4. Bloom, then the final grade (exposure, tonemap, saturation, contrast, vignette, grain) to sRGB 8-bit.
public final class Renderer {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public let evaluator: Evaluator

    /// Pipeline blending. World pipelines have a colour and a circle-of-confusion target: `premulNoCoc` and
    /// `additive` leave the CoC target as it is (shadows, pools, beams, cones); `additiveAll` adds on every target.
    enum Blend { case premul, additive, premulNoCoc, none, additiveAll }

    let shapePSO, texPSO, spritePSO, shadowPSO, beamPSO, poolPSO, contactPSO, conePSO: MTLRenderPipelineState
    let dofPSO, brightPSO, downPSO, upPSO, finalPSO, scalePSO, copyPSO: MTLRenderPipelineState
    let coverPSO, unionPSO: MTLRenderPipelineState
    let sampler: MTLSamplerState
    let glyphs: GlyphCache
    let symbolRasters: SymbolRasterCache
    let textureLoader: MTKTextureLoader
    var images: [String: MTLTexture] = [:]
    var layouts: [String: TextLayout] = [:]
    var atlases: [String: SpriteAtlas] = [:]
    /// Instances computed once per frame and shared by all world phases.
    var frameInstances: [String: [Instance]] = [:]
    /// Interactive preview: skips motion blur (the most expensive effect). Export leaves this off.
    public var draft = false
    /// When set, only these layers (and their descendants) are drawn — used for solo and layer thumbnails.
    public var only: Set<String>?

    /// The theme's `$fg`, the default colour of shapes, text and symbols (white when it isn't a colour).
    var foreground: RGBA { RGBA.parse(evaluator.resolve("$fg")) ?? RGBA(1, 1, 1) }

    /// Visible nodes, honouring `only` (a layer counts if it or any ancestor is listed).
    func drawable(_ nodes: [EvalNode], _ scene: Scene) -> [EvalNode] {
        let visible = nodes.filter { $0.opacity > 0.0001 }
        guard let only, !only.isEmpty else { return visible }
        let parent = Dictionary(scene.nodes.map { ($0.id, $0.parent) }, uniquingKeysWith: { a, _ in a })
        func included(_ id: String) -> Bool {
            var cur: String? = id, hops = 0
            while let c = cur, hops < 64 { if only.contains(c) { return true }; cur = parent[c] ?? nil; hops += 1 }
            return false
        }
        return visible.filter { included($0.node.id) }
    }

    /// Small picture of just one layer in place on the canvas (layer list thumbnails).
    public func thumbnail(
        scene: Scene, project: Project, assets: URL?, layer id: String, time T: Double, width: Int
    ) throws -> CGImage {
        let (cw, _) = project.size(for: scene)
        let saved = (only, draft)
        only = [id]; draft = true
        defer { only = saved.0; draft = saved.1 }
        return try image(scene: scene, project: project, assets: assets, time: T, scale: Double(width) / Double(cw))
    }

    /// Assets folder of the last encoded frame (used by localBounds for images).
    public internal(set) var currentAssets: URL?
    private var targets: RenderTargets?

    public static let hdrFormat: MTLPixelFormat = .rgba16Float
    static let cocFormat: MTLPixelFormat = .rgba16Float
    public static let outFormat: MTLPixelFormat = .bgra8Unorm_srgb
    static let coverFormat: MTLPixelFormat = .r16Float

    public init(evaluator: Evaluator = Evaluator()) throws {
        guard let d = MTLCreateSystemDefaultDevice(), let q = d.makeCommandQueue() else { throw RenderError.noDevice }
        device = d; queue = q; self.evaluator = evaluator
        let lib: MTLLibrary
        do { lib = try d.makeLibrary(source: ShaderSource.main, options: nil) } catch {
            throw RenderError.setup("\(error)")
        }

        func pipeline(
            _ vs: String, _ fs: String, _ formats: [MTLPixelFormat], _ blend: Blend
        ) throws -> MTLRenderPipelineState {
            let p = MTLRenderPipelineDescriptor()
            guard let v = lib.makeFunction(name: vs), let f = lib.makeFunction(name: fs) else {
                throw RenderError.setup("missing \(vs)/\(fs)")
            }
            p.vertexFunction = v; p.fragmentFunction = f
            for (i, fmt) in formats.enumerated() {
                let a = p.colorAttachments[i]!
                a.pixelFormat = fmt
                let isCoc = i == 1
                func blendOne(over destination: MTLBlendFactor) {
                    a.isBlendingEnabled = true
                    a.sourceRGBBlendFactor = .one; a.destinationRGBBlendFactor = destination
                    a.sourceAlphaBlendFactor = .one; a.destinationAlphaBlendFactor = destination
                }
                switch blend {
                case .none: break
                case .premulNoCoc where isCoc, .additive where isCoc: a.writeMask = []
                case .premul, .premulNoCoc: blendOne(over: .oneMinusSourceAlpha)
                case .additive, .additiveAll: blendOne(over: .one)
                }
            }
            return try d.makeRenderPipelineState(descriptor: p)
        }
        let two = [Renderer.hdrFormat, Renderer.cocFormat], one = [Renderer.hdrFormat]
        shapePSO = try pipeline("shape_vs", "shape_fs", two, .premul)
        texPSO = try pipeline("tex_vs", "tex_fs", two, .premul)
        spritePSO = try pipeline("quad_vs", "sprite_fs", two, .premul)
        shadowPSO = try pipeline("quad_vs", "sprite_fs", two, .premulNoCoc)
        beamPSO = try pipeline("quad_vs", "beam_fs", two, .additive)
        poolPSO = try pipeline("decal_vs", "pool_fs", two, .additive)
        contactPSO = try pipeline("decal_vs", "pool_fs", two, .premulNoCoc)
        conePSO = try pipeline("cone_vs", "cone_fs", two, .additive)
        scalePSO = try pipeline("post_vs", "scale_fs", one, .additiveAll)
        copyPSO = try pipeline("post_vs", "copy_fs", [Renderer.outFormat], .none)
        dofPSO = try pipeline("post_vs", "dof_fs", one, .none)
        brightPSO = try pipeline("post_vs", "bright_fs", one, .none)
        downPSO = try pipeline("post_vs", "down_fs", one, .none)
        upPSO = try pipeline("post_vs", "up_fs", one, .additiveAll)
        finalPSO = try pipeline("post_vs", "final_fs", [Renderer.outFormat], .none)
        coverPSO = try pipeline("tex_vs", "cover_fs", [Renderer.coverFormat], .additiveAll)
        unionPSO = try pipeline("post_vs", "union_fs", one, .premul)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear; sd.magFilter = .linear; sd.mipFilter = .linear
        sd.sAddressMode = .clampToEdge; sd.tAddressMode = .clampToEdge
        sd.maxAnisotropy = 8
        sampler = d.makeSamplerState(descriptor: sd)!
        glyphs = GlyphCache(device: d)
        symbolRasters = SymbolRasterCache(device: d)
        textureLoader = MTKTextureLoader(device: d)
    }

    /// Renders one frame to a CGImage (sRGB, premultiplied alpha).
    public func image(
        scene: Scene, project: Project, assets: URL?, time T: Double, scale: Double = 1, transparent: Bool = false
    ) throws -> CGImage {
        let (cw, ch) = project.size(for: scene)
        let w = max(1, Int((Double(cw) * scale).rounded())), h = max(1, Int((Double(ch) * scale).rounded()))
        let t: RenderTargets
        if let cur = targets, cur.width == w, cur.height == h {
            t = cur
        } else {
            t = try makeTargets(width: w, height: h); targets = t
        }
        let od = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Renderer.outFormat, width: w, height: h, mipmapped: false)
        od.usage = [.renderTarget, .shaderRead]; od.storageMode = .shared
        guard let out = device.makeTexture(descriptor: od), let cb = queue.makeCommandBuffer() else {
            throw RenderError.readback
        }
        encode(
            scene: scene, project: project, assets: assets, time: T, scale: scale, transparent: transparent,
            commandBuffer: cb, targets: t, output: out)
        cb.commit()
        cb.waitUntilCompleted()
        if let e = cb.error { throw RenderError.setup("\(e)") }
        return try Renderer.cgImage(from: out)
    }

    private var previewTargets: RenderTargets?
    private var previewOut: MTLTexture?

    /// Renders into a drawable (bgra8Unorm_srgb) for the editor viewport. `resolution` < 1 renders
    /// smaller and upscales, for fast interactive playback.
    public func encodePreview(
        scene: Scene, project: Project, assets: URL?, time T: Double, drawable: MTLTexture,
        resolution: Double, commandBuffer cb: MTLCommandBuffer
    ) {
        let (cw, _) = project.size(for: scene)
        let w = max(1, Int(Double(drawable.width) * resolution)), h = max(1, Int(Double(drawable.height) * resolution))
        if previewTargets?.width != w || previewTargets?.height != h {
            previewTargets = try? makeTargets(width: w, height: h)
        }
        guard let t = previewTargets else { return }
        let scale = Double(w) / Double(cw)
        if resolution >= 0.999 {
            encode(
                scene: scene, project: project, assets: assets, time: T, scale: scale, transparent: false,
                commandBuffer: cb, targets: t, output: drawable)
            return
        }
        if previewOut?.width != w || previewOut?.height != h {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Renderer.outFormat, width: w, height: h, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            previewOut = device.makeTexture(descriptor: d)
        }
        guard let out = previewOut else { return }
        encode(
            scene: scene, project: project, assets: assets, time: T, scale: scale, transparent: false,
            commandBuffer: cb, targets: t, output: out)
        var p = SIMD4<Float>.zero
        fullscreen(cb, target: drawable, pso: copyPSO, textures: [out], params: &p)
    }

    public func makeTargets(width w: Int, height h: Int) throws -> RenderTargets {
        func tex(_ fmt: MTLPixelFormat, _ w: Int, _ h: Int) throws -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: fmt, width: max(w, 1), height: max(h, 1), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]; d.storageMode = .private
            guard let t = device.makeTexture(descriptor: d) else { throw RenderError.setup("textures") }
            return t
        }
        var bloom: [MTLTexture] = []
        for i in 1...6 { bloom.append(try tex(Renderer.hdrFormat, w >> i, h >> i)) }
        return RenderTargets(
            width: w, height: h, hdrA: try tex(Renderer.hdrFormat, w, h), hdrB: try tex(Renderer.hdrFormat, w, h),
            coc: try tex(Renderer.cocFormat, w, h), bloom: bloom, accum: try tex(Renderer.hdrFormat, w, h),
            cover: try tex(Renderer.coverFormat, w, h))
    }
}
