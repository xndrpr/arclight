import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Stills for thumbnails: frames from a video file (at times, or the best-looking faces), or a motion scene rendered
/// at a time. Each becomes a PNG asset — a copy, not a live link.
public enum FrameExtractor {
    public struct Frame: Sendable {
        public let asset: String
        public let time: Double
        public let width: Int
        public let height: Int
        /// Face capture quality (0–1) when frames were picked by `best`.
        public let score: Double?
    }

    public static func duration(_ url: URL) async throws -> Double {
        let d = try await AVURLAsset(url: url).load(.duration)
        return d.seconds.isFinite ? d.seconds : 0
    }

    static func generator(_ url: URL) -> AVAssetImageGenerator {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        g.appliesPreferredTrackTransform = true
        g.requestedTimeToleranceBefore = .zero
        g.requestedTimeToleranceAfter = .zero
        return g
    }

    public static func image(_ url: URL, at t: Double) async throws -> CGImage {
        let (img, _) = try await generator(url).image(at: CMTime(seconds: max(0, t), preferredTimescale: 600))
        return img
    }

    /// Frames at `times` (seconds) from a video, saved as assets.
    public static func frames(video url: URL, times: [Double], store: ProjectStore) async throws -> [Frame] {
        var out: [Frame] = []
        let base = "frame-" + ImageAI.stem(url.lastPathComponent)
        for t in times {
            let img = try await image(url, at: t)
            let name = try ImageAI.write(img, base: base + "-\(Int((t * 100).rounded()))", store: store)
            out.append(Frame(asset: name, time: t, width: img.width, height: img.height, score: nil))
        }
        return out
    }

    /// The `count` best frames: samples the video, scores each by the best face's capture quality (sharp, open eyes,
    /// facing the camera) — or by sharpness when there are no faces — and keeps the top ones at least 1 s apart.
    public static func best(video url: URL, count: Int, samples: Int = 24, store: ProjectStore) async throws -> [Frame] {
        let d = try await duration(url)
        guard d > 0 else { throw ImageAIError.failed("the video has no duration") }
        let n = max(count, min(samples, 60))
        var scored: [(t: Double, s: Double, img: CGImage)] = []
        for i in 0..<n {
            let t = d * (Double(i) + 0.5) / Double(n)
            guard let img = try? await image(url, at: t) else { continue }
            scored.append((t, score(img), img))
        }
        var picked: [(t: Double, s: Double, img: CGImage)] = []
        for c in scored.sorted(by: { $0.s > $1.s }) where picked.count < count {
            if picked.allSatisfy({ abs($0.t - c.t) >= 1 }) { picked.append(c) }
        }
        let base = "frame-" + ImageAI.stem(url.lastPathComponent)
        return try picked.sorted { $0.t < $1.t }.map { p in
            let name = try ImageAI.write(p.img, base: base + "-\(Int((p.t * 100).rounded()))", store: store)
            return Frame(asset: name, time: p.t, width: p.img.width, height: p.img.height, score: p.s)
        }
    }

    /// Face capture quality of the best face (plus a bonus for any face), else a small sharpness-only score.
    static func score(_ img: CGImage) -> Double {
        let req = VNDetectFaceCaptureQualityRequest()
        let h = VNImageRequestHandler(cgImage: img, options: [:])
        try? h.perform([req])
        if let best = req.results?.compactMap({ $0.faceCaptureQuality }).max() { return 0.5 + Double(best) / 2 }
        return min(0.45, sharpness(img) * 0.45)
    }

    /// Mean absolute luminance gradient on a small greyscale copy (0–1).
    static func sharpness(_ img: CGImage) -> Double {
        let w = 160, h = max(1, 160 * img.height / max(img.width, 1))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0 }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let d = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        var sum = 0.0
        for y in 0..<(h - 1) {
            for x in 0..<(w - 1) {
                let p = Double(d[y * w + x])
                sum += abs(p - Double(d[y * w + x + 1])) + abs(p - Double(d[(y + 1) * w + x]))
            }
        }
        return min(1, sum / Double(max(1, (w - 1) * (h - 1))) / 40)
    }

    /// A motion scene rendered at `time` (default: its middle), saved as an asset.
    public static func snapshot(
        scene: Scene, time: Double?, project: Project, store: ProjectStore, renderer: Renderer
    ) throws -> Frame {
        let t = time ?? scene.duration / 2
        let img = try renderer.image(scene: scene, project: project, assets: store.assetsURL, time: t)
        let name = try ImageAI.write(img, base: "scene-\(scene.id)-\(Int((t * 100).rounded()))", store: store)
        return Frame(asset: name, time: t, width: img.width, height: img.height, score: nil)
    }
}
