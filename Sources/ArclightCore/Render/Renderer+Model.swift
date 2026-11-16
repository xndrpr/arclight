import Foundation
import Metal
import MetalKit
import simd

/// GPU uniforms for one mesh part (`mesh_vs` / `mesh_fs` in Shaders+Space.swift).
struct MeshU {
    var mvp: simd_float4x4
    var world: simd_float4x4
    /// Premultiplied linear tint (opacity included).
    var color: SIMD4<Float>
    /// Direction towards the light (world), w = 1 when the part has a texture.
    var light: SIMD4<Float>
    /// Camera position (world), w = material (0 matte, 1 glossy, 2 clay).
    var eye: SIMD4<Float>
    /// shade, rim, 0, 0
    var params: SIMD4<Float>
}

/// A loaded model on the GPU.
final class GPUMesh {
    let vertices: MTLBuffer
    let indices: MTLBuffer
    let parts: [(start: Int, count: Int, color: SIMD4<Float>, texture: MTLTexture?)]
    let center: SIMD3<Float>
    /// Largest side of the bounds (model units).
    let extent: Float
    /// Bottom of the bounds (largest y: y points down).
    let bottom: Float
    /// Bones, shape keys and clips, when the model can move (`uvs` go with the posed vertices).
    let rig: Rig?
    let uvs: [SIMD2<Float>]

    init(vertices: MTLBuffer, indices: MTLBuffer, parts: [(Int, Int, SIMD4<Float>, MTLTexture?)], mesh: Mesh) {
        self.vertices = vertices; self.indices = indices
        rig = mesh.rig?.animated == true ? mesh.rig : nil
        uvs = rig == nil ? [] : mesh.vertices.map(\.uv)
        self.parts = parts.map { (start: $0.0, count: $0.1, color: $0.2, texture: $0.3) }
        let b = mesh.bounds
        center = (b.min + b.max) / 2
        extent = max(b.max.x - b.min.x, b.max.y - b.min.y, b.max.z - b.min.z, 1e-6)
        bottom = b.max.y
    }
}

extension Renderer {
    /// The model file at `src` on the GPU, cached by path and modification date (nil when it can't be read).
    func gpuMesh(src: String, assets: URL?) -> GPUMesh? {
        let url = AssetPath.url(src, assets: assets)
        let stamp =
            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(url.path)#\(stamp)"
        if let m = meshes[key] { return m ?? nil }
        let built = (try? Mesh.load(url)).flatMap { makeGPUMesh($0) }
        meshes = meshes.filter { !$0.key.hasPrefix(url.path + "#") }
        meshes[key] = .some(built)
        return built
    }

    func makeGPUMesh(_ mesh: Mesh) -> GPUMesh? {
        guard !mesh.vertices.isEmpty, !mesh.indices.isEmpty,
            let vb = vertexBuffer(
                positions: mesh.vertices.map(\.position), normals: mesh.vertices.map(\.normal),
                uvs: mesh.vertices.map(\.uv)),
            let ib = device.makeBuffer(bytes: mesh.indices, length: mesh.indices.count * 4)
        else { return nil }
        let parts = mesh.parts.map { p -> (Int, Int, SIMD4<Float>, MTLTexture?) in
            let t = p.texture.flatMap {
                try? textureLoader.newTexture(
                    data: $0,
                    options: [
                        .SRGB: true, .generateMipmaps: true, .allocateMipmaps: true,
                        .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                        .textureStorageMode: MTLStorageMode.private.rawValue, .origin: MTKTextureLoader.Origin.topLeft,
                    ])
            }
            return (p.start, p.count, p.color, t)
        }
        return GPUMesh(vertices: vb, indices: ib, parts: parts, mesh: mesh)
    }

    /// float4 position, float4 normal, float4 uv (48 bytes, matches MeshV in the shader).
    func vertexBuffer(positions: [SIMD3<Float>], normals: [SIMD3<Float>], uvs: [SIMD2<Float>]) -> MTLBuffer? {
        var v = [SIMD4<Float>]()
        v.reserveCapacity(positions.count * 3)
        for k in positions.indices {
            let uv = k < uvs.count ? uvs[k] : .zero
            v.append(SIMD4(positions[k], 1)); v.append(SIMD4(k < normals.count ? normals[k] : .zero, 0))
            v.append(SIMD4(uv.x, uv.y, 0, 0))
        }
        guard !v.isEmpty else { return nil }
        return device.makeBuffer(bytes: v, length: v.count * MemoryLayout<SIMD4<Float>>.stride)
    }

    /// Which clip a model layer plays and where in it (seconds), or nil when it stands still.
    static func clipTime(_ n: EvalNode, rig: Rig) -> (clip: Int, time: Float)? {
        guard let i = rig.clipIndex(n.str("clip", "")), rig.clips[i].duration > 0 else { return nil }
        let d = Double(rig.clips[i].duration)
        var t = n.props["clipTime"]?.double ?? (n.t * n.num("clipSpeed", 1) + n.num("clipOffset", 0))
        if n.bool("clipLoop", true) {
            t = t.truncatingRemainder(dividingBy: d)
            if t < 0 { t += d }
        } else {
            t = min(max(t, 0), d)
        }
        return (i, Float(t))
    }

    /// The model's vertices posed for this layer, cached by pose (copies in step share one buffer).
    func posedVertices(_ m: GPUMesh, _ n: EvalNode) -> MTLBuffer {
        guard let rig = m.rig, let ct = Renderer.clipTime(n, rig: rig) else { return m.vertices }
        // A 1/1000 s grid: frames that land on the same pose reuse it.
        let key = "\(ObjectIdentifier(m).hashValue)|\(ct.clip)|\(Int((ct.time * 1000).rounded()))"
        if let b = posedCache[key] { return b }
        let p = rig.pose(clip: ct.clip, time: ct.time)
        guard let b = vertexBuffer(positions: p.positions, normals: p.normals, uvs: m.uvs) else { return m.vertices }
        if posedCache.count > 96 { posedCache.removeAll(keepingCapacity: true) }
        posedCache[key] = b
        return b
    }

    /// The matrix that takes a model's own units to the layer: centred on its bounds (or standing on them with
    /// `pivot` "bottom") and scaled so its largest side is `size` px.
    static func modelFit(_ m: GPUMesh, size: Float, pivot: String) -> simd_float4x4 {
        let s = size / m.extent
        var c = m.center
        if pivot == "bottom" { c.y = m.bottom }
        return M.scale(s, s, s) * M.translate(-c.x, -c.y, -c.z)
    }

    /// A model layer, opaque, lit by the layer's light direction. Writes depth.
    func drawModel(_ n: EvalNode, cam: CameraState, assets: URL?, enc: MTLRenderCommandEncoder) {
        guard let m = gpuMesh(src: n.str("src", ""), assets: assets) else { return }
        let fit = Renderer.modelFit(m, size: Float(max(n.num("size", 400), 0.001)), pivot: n.str("pivot", "center"))
        let world = n.world * fit
        let l = n.props["light"]?.doubles ?? [-0.4, -1, -0.6]
        var toLight = l.count >= 3 ? SIMD3(Float(l[0]), Float(l[1]), Float(l[2])) : SIMD3(-0.4, -1, -0.6)
        toLight = simd_length(toLight) > 1e-6 ? simd_normalize(toLight) : SIMD3(0, -1, 0)
        let material: Float = ["matte": 0, "glossy": 1, "clay": 2][n.str("material", "matte")] ?? 0
        let tint = n.color("color")
        enc.setRenderPipelineState(meshPSO)
        enc.setDepthStencilState(depthWrite)
        enc.setVertexBuffer(posedVertices(m, n), offset: 0, index: 1)
        for p in m.parts {
            // The tint replaces a plain part's colour; a textured part keeps its picture, tinted.
            var base = p.color
            if let tint {
                let t = tint.linearPremultiplied()
                base = p.texture == nil ? SIMD4(t.x, t.y, t.z, t.w) : base * SIMD4(t.x, t.y, t.z, t.w)
            }
            let op = Float(n.opacity) * base.w
            var u = MeshU(
                mvp: cam.viewProj * world, world: world,
                color: SIMD4(base.x * op, base.y * op, base.z * op, op),
                light: SIMD4(toLight, p.texture == nil ? 0 : 1), eye: SIMD4(cam.position, material),
                params: SIMD4(Float(min(max(n.num("shade", 0.7), 0), 1)), Float(max(n.num("rim", 0), 0)), 0, 0))
            enc.setVertexBytes(&u, length: MemoryLayout<MeshU>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<MeshU>.stride, index: 0)
            enc.setFragmentTexture(p.texture ?? whiteTexture, index: 0)
            enc.drawIndexedPrimitives(
                type: .triangle, indexCount: p.count, indexType: .uint32, indexBuffer: m.indices,
                indexBufferOffset: p.start * 4)
        }
        enc.setDepthStencilState(depthTest)
    }
}
