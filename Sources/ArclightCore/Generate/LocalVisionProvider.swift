import CoreGraphics
import CoreImage
import Foundation
import Vision

/// On-device image operations with Apple Vision: free, offline, no key. Background removal and subject finding.
public struct LocalVisionProvider: Sendable {
    public init() {}

    /// The foreground instances (people, animals, objects) cut out on a transparent background.
    public func removeBackground(image: CGImage) throws -> CGImage {
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([req])
        guard let obs = req.results?.first, !obs.allInstances.isEmpty else {
            throw ImageAIError.failed("no subject found in the picture")
        }
        let buffer = try obs.generateMaskedImage(
            ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let out = CIContext().createCGImage(ci, from: ci.extent) else { throw ImageAIError.badImage }
        return out
    }

    /// Bounding box of the foreground subject(s), top-left origin, in image pixels.
    public func subjectBounds(image: CGImage) throws -> CGRect? {
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([req])
        guard let obs = req.results?.first, !obs.allInstances.isEmpty else { return nil }
        let mask = try obs.generateScaledMaskForImage(forInstances: obs.allInstances, from: handler)
        let ci = CIImage(cvPixelBuffer: mask)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        return LocalVisionProvider.alphaBounds(cg, threshold: 0.5)
    }

    /// Bounding box (top-left origin) of pixels whose first channel is above `threshold` (masks are greyscale).
    static func alphaBounds(_ img: CGImage, threshold: Double) -> CGRect? {
        let w = img.width, h = img.height
        guard let ctx = ImageData.context(w, h) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let bpr = ctx.bytesPerRow, t = UInt8(threshold * 255)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            for x in 0..<w where data[y * bpr + x * 4] > t {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
