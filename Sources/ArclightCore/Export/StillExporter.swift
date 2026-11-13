import CoreGraphics
import Foundation
import ImageIO

/// Image formats for preview artboards.
public enum StillFormat: String, CaseIterable, Sendable {
    case png, jpg
    public var ext: String { rawValue }
}

/// Encoding helpers for stills (thumbnails).
extension ImageFile {
    /// JPEG bytes at `quality` (0…1), flattened onto opaque black (JPEG has no alpha).
    public static func jpegData(_ img: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        let opts: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageDestinationBackgroundColor: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
        ]
        CGImageDestinationAddImage(dest, img, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// The best-quality JPEG that fits in `maxBytes`: tries 0.92 and steps down to 0.4. Returns the last attempt if
    /// even that is too big (the caller reports the size), and the quality used.
    public static func jpegFitting(_ img: CGImage, maxBytes: Int) -> (data: Data, quality: Double)? {
        var last: (Data, Double)?
        for q in stride(from: 0.92, through: 0.399, by: -0.06) {
            guard let d = jpegData(img, quality: q) else { return nil }
            last = (d, q)
            if d.count <= maxBytes { return (d, q) }
        }
        return last.map { ($0.0, $0.1) }
    }
}

/// Exports preview artboards as PNG or JPG. The YouTube preset renders 1280×720 (or the artboard's own size scaled
/// to 720p height for other ratios) as a JPG under YouTube's 2 MB thumbnail limit.
public struct StillExporter {
    public static let youtubeMaxBytes = 2 * 1024 * 1024

    public struct Options: Sendable {
        public var format: StillFormat = .png
        public var scale: Double = 1
        public var transparent = false
        /// JPG quality 0…1; nil = the best that fits `maxBytes` (or 0.92 without a limit).
        public var quality: Double?
        public var maxBytes: Int?
        public init() {}

        public static var youtube: Options {
            var o = Options(); o.format = .jpg; o.maxBytes = StillExporter.youtubeMaxBytes; return o
        }
    }

    public struct Result: Sendable {
        public let url: URL
        public let width: Int
        public let height: Int
        public let bytes: Int
        public let quality: Double?
        public var overLimit: Bool
    }

    let renderer: Renderer
    public init(renderer: Renderer) { self.renderer = renderer }

    public func export(
        artboard: Artboard, preview: Preview, project: Project, assets: URL?, to url: URL, options o: Options
    ) throws -> Result {
        let saved = (renderer.draft, renderer.only)
        renderer.draft = false; renderer.only = nil
        defer { renderer.draft = saved.0; renderer.only = saved.1 }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let scene = artboard.asScene(preview: preview.id, rev: preview.rev)
        let img = try renderer.image(
            scene: scene, project: project.rendering(preview), assets: assets, time: 0, scale: o.scale,
            transparent: o.transparent && o.format == .png)
        switch o.format {
        case .png:
            try ImageFile.writePNG(img, to: url)
            let n = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return Result(
                url: url, width: img.width, height: img.height, bytes: n, quality: nil,
                overLimit: o.maxBytes.map { n > $0 } ?? false)
        case .jpg:
            let enc: (data: Data, quality: Double)?
            if let q = o.quality {
                enc = ImageFile.jpegData(img, quality: q).map { ($0, q) }
            } else if let m = o.maxBytes {
                enc = ImageFile.jpegFitting(img, maxBytes: m)
            } else {
                enc = ImageFile.jpegData(img, quality: 0.92).map { ($0, 0.92) }
            }
            guard let enc else { throw RenderError.readback }
            try enc.data.write(to: url, options: .atomic)
            return Result(
                url: url, width: img.width, height: img.height, bytes: enc.data.count, quality: enc.quality,
                overLimit: o.maxBytes.map { enc.data.count > $0 } ?? false)
        }
    }

    /// Export scale for the YouTube preset: 16:9 artboards come out at exactly 1280×720 (YouTube's recommended
    /// thumbnail size); other ratios (Shorts covers, squares) keep their own size.
    public static func youtubeScale(for a: Artboard) -> Double {
        let ratio = Double(a.width) / Double(max(a.height, 1))
        return abs(ratio - 16.0 / 9.0) < 0.01 ? 1280 / Double(max(a.width, 1)) : 1
    }
}
