import CoreGraphics
import Foundation
import Metal
import simd

extension TexU {
    /// A clip rect that clips nothing.
    static let noClip = SIMD4<Float>(-1e7, -1e7, 1e7, 1e7)
}

extension Renderer {
    func texture(src: String, assets: URL?) -> MTLTexture? {
        let url = AssetPath.url(src, assets: assets)
        // Keyed by path + modification date, so an asset rewritten under the same name (asset_write) shows up.
        let stamp =
            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(url.path)#\(stamp)"
        if let t = images[key] { return t }
        let t = try? textureLoader.newTexture(
            URL: url,
            options: [
                .SRGB: true, .generateMipmaps: true, .allocateMipmaps: true,
                .textureUsage: MTLTextureUsage.shaderRead.rawValue,
                .textureStorageMode: MTLStorageMode.private.rawValue,
            ])
        if let t { images = images.filter { !$0.key.hasPrefix(url.path + "#") }; images[key] = t }
        return t
    }

    func drawImage(_ n: EvalNode, mvp: simd_float4x4, assets: URL?, enc: MTLRenderCommandEncoder) {
        guard let tex = texture(src: n.str("src", ""), assets: assets) else { return }
        let size = imageSize(n, texture: tex)
        var u = TexU(
            mvp: mvp, unit: matrix_identity_float4x4,
            rect: SIMD4(Float(-size.width / 2), Float(-size.height / 2), Float(size.width), Float(size.height)),
            color: SIMD4(1, 1, 1, Float(n.opacity)), clip: TexU.noClip, mode: SIMD4(1, 0, 0, 0))
        enc.setRenderPipelineState(texPSO)
        drawTexturedQuad(&u, texture: tex, enc: enc)
    }

    /// An image layer's size: `width`/`height`, the missing one from the image's aspect, or the image's pixels.
    func imageSize(_ n: EvalNode, texture tex: MTLTexture) -> CGSize {
        let aspect = Double(tex.width) / Double(max(tex.height, 1))
        var w = n.props["width"]?.double, h = n.props["height"]?.double
        if w == nil && h == nil {
            w = Double(tex.width); h = Double(tex.height)
        } else if w == nil {
            w = h! * aspect
        } else if h == nil {
            h = w! / aspect
        }
        return CGSize(width: w!, height: h!)
    }

    /// Draws one `tex_fs` quad; the caller has set the pipeline.
    func drawTexturedQuad(_ u: inout TexU, texture: MTLTexture, enc: MTLRenderCommandEncoder) {
        enc.setVertexBytes(&u, length: MemoryLayout<TexU>.stride, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<TexU>.stride, index: 0)
        enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
}
