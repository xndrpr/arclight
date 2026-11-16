import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// AI image operations. `LocalVisionProvider` (always available, offline) removes backgrounds and finds subjects;
/// `FalProvider` (optional, the user's fal.ai key) generates, fills, expands and upscales.
public protocol ImageProvider: Sendable {
    var name: String { get }
    func generate(prompt: String, width: Int, height: Int, seed: Int?) async throws -> CGImage
    /// Inpaint: replaces the white area of `mask` (same size as `image`) following `prompt`.
    func fill(image: CGImage, mask: CGImage, prompt: String, seed: Int?) async throws -> CGImage
    func removeBackground(image: CGImage) async throws -> CGImage
    func upscale(image: CGImage, factor: Int) async throws -> CGImage
    /// Depth map, same size or aspect as `image`: white is near, black far.
    func depth(image: CGImage) async throws -> CGImage
    /// A 3D model of the object in `image` (best on a plain or transparent background), as .glb bytes.
    func model3D(image: CGImage) async throws -> Data
}

extension ImageProvider {
    public func model3D(image: CGImage) async throws -> Data {
        throw ImageAIError.unsupported("\(name) can't make 3D models")
    }

    public func depth(image: CGImage) async throws -> CGImage {
        throw ImageAIError.unsupported("\(name) can't make depth maps")
    }
}

public enum ImageAIError: Error, CustomStringConvertible, Equatable {
    case noKey
    case unsupported(String)
    case http(Int, String)
    case failed(String)
    case badImage

    public var description: String {
        switch self {
        case .noKey:
            return
                "image generation is off: add a fal.ai API key in Settings ▸ AI (or set FAL_KEY for agents and the CLI). Background removal works without one."
        case .unsupported(let s): return s
        case .http(let code, let body): return "fal.ai returned HTTP \(code): \(body.prefix(300))"
        case .failed(let s): return s
        case .badImage: return "not a readable image"
        }
    }
}

/// PNG / JPEG encoding and decoding for provider payloads.
public enum ImageData {
    public static func png(_ img: CGImage) -> Data? { encode(img, type: UTType.png.identifier) }

    public static func encode(_ img: CGImage, type: String, quality: Double? = nil) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, type as CFString, 1, nil) else {
            return nil
        }
        let opts: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(dest, img, opts as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    public static func decode(_ data: Data) throws -> CGImage {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
            let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw ImageAIError.badImage }
        return img
    }

    public static func load(_ url: URL) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw ImageAIError.badImage }
        return img
    }

    /// A `data:` URI, which fal accepts wherever it takes an image URL.
    public static func dataURI(_ img: CGImage) throws -> String {
        guard let d = png(img) else { throw ImageAIError.badImage }
        return "data:image/png;base64," + d.base64EncodedString()
    }

    /// An RGBA bitmap context of `w`×`h` (sRGB, premultiplied), cleared.
    public static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(
            data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    /// Black image with a white rectangle (top-left origin rect), for inpainting masks.
    public static func mask(width w: Int, height h: Int, white r: CGRect) -> CGImage? {
        guard let ctx = context(w, h) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: r.minX, y: CGFloat(h) - r.maxY, width: r.width, height: r.height))
        return ctx.makeImage()
    }

    /// `img` cropped to `r` (top-left origin, pixels).
    public static func crop(_ img: CGImage, _ r: CGRect) -> CGImage? {
        img.cropping(to: r.integral.intersection(CGRect(x: 0, y: 0, width: img.width, height: img.height)))
    }

    /// `img` resampled to `w`×`h`.
    public static func resize(_ img: CGImage, _ w: Int, _ h: Int) -> CGImage? {
        guard let ctx = context(w, h) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Outpainting input: `img` placed on a larger canvas (`left`/`top`/`right`/`bottom` px added, filled with the
    /// picture's edge-blurred average so the model has context), plus a mask that is white over the new area.
    public static func padded(_ img: CGImage, left: Int, top: Int, right: Int, bottom: Int) -> (CGImage, CGImage)? {
        let w = img.width + left + right, h = img.height + top + bottom
        guard let ctx = context(w, h) else { return nil }
        // Stretched picture as a rough backdrop, then the picture itself.
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: left, y: bottom, width: img.width, height: img.height))
        guard let canvas = ctx.makeImage(), let m = context(w, h) else { return nil }
        m.setFillColor(CGColor(gray: 1, alpha: 1)); m.fill(CGRect(x: 0, y: 0, width: w, height: h))
        m.setFillColor(CGColor(gray: 0, alpha: 1))
        // Keep a few pixels of overlap white so the seam blends.
        let k = 4
        m.fill(CGRect(x: left + k, y: bottom + k, width: max(0, img.width - 2 * k), height: max(0, img.height - 2 * k)))
        guard let mask = m.makeImage() else { return nil }
        return (canvas, mask)
    }
}
