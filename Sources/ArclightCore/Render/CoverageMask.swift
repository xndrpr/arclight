import CoreGraphics
import Metal

/// 8-bit coverage masks for glyphs and symbols: drawn white on black, uploaded as `r8Unorm` and tinted in the shader.
enum CoverageMask {
    /// An anti-aliased grey bitmap context whose fill colour is white.
    static func context(width: Int, height: Int) -> CGContext? {
        guard
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setShouldAntialias(true)
        ctx.setFillColor(gray: 1, alpha: 1)
        return ctx
    }

    /// The context's pixels as a shader-readable texture.
    static func texture(_ ctx: CGContext, device: MTLDevice) -> MTLTexture? {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: ctx.width, height: ctx.height, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc), let data = ctx.data else { return nil }
        tex.replace(
            region: MTLRegionMake2D(0, 0, ctx.width, ctx.height), mipmapLevel: 0, withBytes: data,
            bytesPerRow: ctx.bytesPerRow)
        return tex
    }
}
