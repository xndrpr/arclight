import CoreGraphics
import Foundation
import ImageIO

/// Image formats for thumbnail artboards.
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

/// Exports thumbnail artboards as PNG or JPG, always with the artboard's own aspect ratio. The YouTube preset is a JPG
/// under YouTube's 2 MB thumbnail limit at 1280×720 turned to the artboard's orientation (see `youtubeScale`).
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
        artboard: Artboard, thumbnail: Thumbnail, project: Project, assets: URL?, to url: URL, options o: Options
    ) throws -> Result {
        let saved = (renderer.draft, renderer.only)
        renderer.draft = false; renderer.only = nil
        defer { renderer.draft = saved.0; renderer.only = saved.1 }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let scene = artboard.asScene(thumbnail: thumbnail.id, rev: thumbnail.rev)
        let img = try renderer.image(
            scene: scene, project: project.rendering(thumbnail), assets: assets, time: 0, scale: o.scale,
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

    /// Export scale for the YouTube preset: YouTube's 1280×720 thumbnail size turned to the artboard's orientation, so
    /// 16:9 comes out at exactly 1280×720 and 9:16 (a Shorts cover) at 720×1280; other ratios fit inside that frame
    /// with their own aspect (a square at 720×720, 4:5 at 720×900). Never stretched or letterboxed.
    public static func youtubeScale(for a: Artboard) -> Double {
        let long = Double(max(a.width, a.height, 1)), short = Double(max(min(a.width, a.height), 1))
        return min(Double(Artboard.youtubeSize[0]) / long, Double(Artboard.youtubeSize[1]) / short)
    }

    /// The pixel size `export` writes `a` at with `scale`.
    public static func pixelSize(of a: Artboard, scale: Double) -> (width: Int, height: Int) {
        Renderer.pixelSize(width: a.width, height: a.height, scale: scale)
    }
}
