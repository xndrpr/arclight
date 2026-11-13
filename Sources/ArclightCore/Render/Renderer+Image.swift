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
        let q = Renderer.imageQuad(n, box: imageSize(n, texture: tex), texture: (tex.width, tex.height))
        var u = TexU(
            mvp: mvp, unit: matrix_identity_float4x4, rect: q.rect,
            color: SIMD4(1, 1, 1, Float(n.opacity)), clip: q.clip, mode: SIMD4(1, 0, 0, 0))
        enc.setRenderPipelineState(texPSO)
        drawTexturedQuad(&u, texture: tex, enc: enc)
    }

    /// The quad for an image layer in its box (centred on 0,0): `crop` picks part of the picture (fractions
    /// [x, y, w, h]); with both width and height set, `fit` cover fills the box and crops the overflow, contain fits
    /// inside it, stretch (default) fills it. The whole picture is drawn scaled and the clip rect keeps the crop.
    static func imageQuad(_ n: EvalNode, box: CGSize, texture: (Int, Int)) -> (rect: SIMD4<Float>, clip: SIMD4<Float>) {
        var c = [0.0, 0.0, 1.0, 1.0]
        if let a = n.props["crop"]?.doubles, a.count == 4 {
            let x = min(max(a[0], 0), 1), y = min(max(a[1], 0), 1)
            c = [x, y, min(max(a[2], 0.001), 1 - x), min(max(a[3], 0.001), 1 - y)]
        }
        var w = Double(box.width), h = Double(box.height)
        let boxed = n.props["width"] != nil && n.props["height"] != nil
        let fit = boxed ? n.str("fit", "stretch") : "stretch"
        let visible = Double(texture.0) * c[2] / max(Double(texture.1) * c[3], 1e-6)  // aspect of the shown part
        let boxAspect = w / max(h, 1e-6)
        if fit == "cover" {
            if visible > boxAspect {
                let nw = c[2] * boxAspect / visible; c[0] += (c[2] - nw) / 2; c[2] = nw
            } else {
                let nh = c[3] * visible / boxAspect; c[1] += (c[3] - nh) / 2; c[3] = nh
            }
        } else if fit == "contain" {
            if visible > boxAspect { h = w / visible } else { w = h * visible }
        } else if !boxed, n.props["crop"] != nil {
            // No box given: the cropped part keeps its own aspect at the layer's width (or pixel size).
            h = w / visible
        }
        let fw = w / c[2], fh = h / c[3]
        let rect = SIMD4<Float>(Float(-w / 2 - c[0] * fw), Float(-h / 2 - c[1] * fh), Float(fw), Float(fh))
        let cropped = c != [0, 0, 1, 1]
        let clip = cropped ? SIMD4<Float>(Float(-w / 2), Float(-h / 2), Float(w / 2), Float(h / 2)) : TexU.noClip
        return (rect, clip)
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
