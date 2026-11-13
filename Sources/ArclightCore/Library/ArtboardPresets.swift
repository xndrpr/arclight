import CoreGraphics
import CoreText
import Foundation

/// Named artboard sizes for previews.
public enum ArtboardPresets {
    public struct Preset: Sendable, Hashable {
        public let id: String
        public let title: String
        public let size: [Int]
    }

    public static let all: [Preset] = [
        Preset(id: "youtube", title: "YouTube thumbnail · 1280×720", size: [1280, 720]),
        Preset(id: "youtube-hd", title: "YouTube thumbnail HD · 1920×1080", size: [1920, 1080]),
        Preset(id: "shorts", title: "Shorts cover · 1080×1920", size: [1080, 1920]),
        Preset(id: "square", title: "Square · 1080×1080", size: [1080, 1080]),
        Preset(id: "portrait", title: "Portrait 4:5 · 1080×1350", size: [1080, 1350]),
        Preset(id: "banner", title: "Channel banner · 2560×1440", size: [2560, 1440]),
    ]

    public static var names: [String] { all.map(\.id) }
    public static func size(_ id: String) -> [Int]? { all.first { $0.id == id.lowercased() }?.size }
}

/// How a thumbnail looks in the YouTube feed: YouTube draws the video length in a dark rounded badge over the
/// bottom-right corner, so whatever sits there is hidden.
public enum FeedMock {
    /// The badge rectangle for an image `w`×`h` (top-left origin), in pixels.
    public static func badgeRect(width w: Double, height h: Double) -> CGRect {
        let bh = max(8, h * 0.11), bw = bh * 2.6, m = max(2, h * 0.035)
        return CGRect(x: w - bw - m, y: h - bh - m, width: bw, height: bh)
    }

    /// A copy of `img` with a "12:34" timestamp badge in the bottom-right corner.
    public static func badge(_ img: CGImage, label: String = "12:34") -> CGImage {
        let w = img.width, h = img.height
        guard
            let ctx = CGContext(
                data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let r = badgeRect(width: Double(w), height: Double(h))
        let cg = CGRect(x: r.minX, y: Double(h) - r.maxY, width: r.width, height: r.height)  // flip to CG
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.8))
        ctx.addPath(CGPath(roundedRect: cg, cornerWidth: r.height * 0.2, cornerHeight: r.height * 0.2, transform: nil))
        ctx.fillPath()
        let font = CTFontCreateWithName("HelveticaNeue-Medium" as CFString, r.height * 0.62, nil)
        let attr = NSAttributedString(
            string: label,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                    red: 1, green: 1, blue: 1, alpha: 1),
            ])
        let line = CTLineCreateWithAttributedString(attr)
        let lw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        ctx.textPosition = CGPoint(x: cg.midX - lw / 2, y: cg.minY + r.height * 0.27)
        CTLineDraw(line, ctx)
        return ctx.makeImage() ?? img
    }
}
