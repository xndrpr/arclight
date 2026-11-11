import CoreGraphics
import CoreText
import Foundation
import ImageIO

/// Several frames of a scene tiled into one small labelled image — cheap visual feedback for agents.
public enum ContactSheet {
    public static func render(
        renderer: Renderer, scene: Scene, project: Project, assets: URL?,
        times: [Double], scale: Double
    ) throws -> CGImage {
        let frames = try times.map {
            try renderer.image(scene: scene, project: project, assets: assets, time: $0, scale: scale)
        }
        guard let f0 = frames.first else { throw RenderError.readback }
        let cols = frames.count <= 1 ? 1 : frames.count <= 4 ? 2 : 3
        let rows = (frames.count + cols - 1) / cols
        let gap = 4, fw = f0.width, fh = f0.height
        let W = cols * fw + (cols - 1) * gap, H = rows * fh + (rows - 1) * gap
        guard
            let ctx = CGContext(
                data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw RenderError.readback }
        ctx.setFillColor(CGColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        let font = CTFontCreateWithName("Menlo-Bold" as CFString, max(10, CGFloat(fh) / 18), nil)
        for (i, img) in frames.enumerated() {
            let c = i % cols, r = i / cols
            let x = c * (fw + gap), y = H - (r + 1) * fh - r * gap  // CG origin bottom-left
            ctx.draw(img, in: CGRect(x: x, y: y, width: fw, height: fh))
            let label = String(format: "t=%.2fs", times[i])
            let attr = NSAttributedString(
                string: label,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                        red: 1, green: 0.85, blue: 0, alpha: 1),
                ])
            let line = CTLineCreateWithAttributedString(attr)
            let pad = CGFloat(fh) / 40
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
            let lw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.fill(CGRect(x: CGFloat(x), y: CGFloat(y), width: lw + pad * 2, height: CTFontGetSize(font) * 1.4 + pad))
            ctx.textPosition = CGPoint(x: CGFloat(x) + pad, y: CGFloat(y) + pad)
            CTLineDraw(line, ctx)
        }
        guard let out = ctx.makeImage() else { throw RenderError.readback }
        return out
    }

    public static func jpeg(_ img: CGImage, quality: Double = 0.8) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
