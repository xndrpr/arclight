import AVFoundation
import CoreVideo
import Foundation
import Metal

public enum ExportFormat: String, CaseIterable, Sendable {
    /// H.264 MP4 — universal upload format.
    case mp4
    /// HEVC MP4 — smaller files at the same quality.
    case hevc
    /// ProRes 4444 MOV with alpha — for overlaying in an NLE.
    case prores
    /// PNG image sequence (one file per frame) in a folder.
    case png

    var fileType: AVFileType { self == .prores ? .mov : .mp4 }
    /// File extension (for png: the sequence is written to a folder named "<scene>_png").
    public var ext: String {
        switch self {
        case .mp4: return "mp4";
        case .hevc: return "hevc.mp4";
        case .prores: return "mov";
        case .png: return "png"
        }
    }
    var codec: AVVideoCodecType {
        switch self {
        case .mp4, .png: return .h264;
        case .hevc: return .hevc;
        case .prores: return .proRes4444
        }
    }
}

public struct ExportOptions: Sendable {
    public var format: ExportFormat = .mp4
    public var scale: Double = 1
    public var fps: Double?
    /// Average bitrate for mp4/hevc. Default scales with resolution (~16 Mbps at 1080p30 for H.264).
    public var bitrateMbps: Double?
    /// Transparent background: ProRes (default true) and PNG sequences (default false); ignored for mp4/hevc.
    public var transparent: Bool?
    public init() {}
}

public struct ExportResult: Sendable {
    public var url: URL
    public var frames: Int
    public var width: Int, height: Int
    public var fps: Double
    public var seconds: Double
}

/// Renders a scene frame by frame straight into encoder-owned pixel buffers (zero-copy) and
/// writes them with AVAssetWriter, which uses the hardware encoders.
public final class Exporter {
    let renderer: Renderer
    public init(renderer: Renderer) { self.renderer = renderer }

    public func export(
        scene: Scene, project: Project, assets: URL?, to url: URL, options o: ExportOptions,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> ExportResult {
        // Export draws every layer at full quality, whatever the editor viewport left set (draft preview, solo).
        let saved = (renderer.draft, renderer.only)
        renderer.draft = false; renderer.only = nil
        defer { renderer.draft = saved.0; renderer.only = saved.1 }
        try Exporter.checkNumbers(scene: scene, project: project, options: o)
        if o.format == .png {
            return try exportPNGSequence(
                scene: scene, project: project, assets: assets, to: url, options: o, progress: progress)
        }
        let start = Date()
        let (cw, ch) = project.size(for: scene)
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        let w = even(Double(cw) * o.scale), h = even(Double(ch) * o.scale)
        let fps = o.fps ?? scene.fps ?? project.fps
        let frames = max(1, Int((scene.duration * fps).rounded(.up)))
        let transparent = o.format == .prores ? (o.transparent ?? true) : false

        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let writer = try AVAssetWriter(outputURL: url, fileType: o.format.fileType)

        var settings: [String: Any] = [
            AVVideoCodecKey: o.format.codec, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if o.format != .prores {
            let pixelsPerSec = Double(w * h) * fps
            let defaultMbps = pixelsPerSec * (o.format == .hevc ? 0.15 : 0.25) / 1e6
            var comp: [String: Any] = [
                AVVideoAverageBitRateKey: Int((o.bitrateMbps ?? defaultMbps) * 1e6),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: Int(fps * 2),
            ]
            if o.format == .mp4 { comp[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
            settings[AVVideoCompressionPropertiesKey] = comp
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ])
        guard writer.canAdd(input) else { throw RenderError.setup("writer rejected video settings") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RenderError.setup("cannot start writer") }
        writer.startSession(atSourceTime: .zero)

        var cacheRef: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, renderer.device, nil, &cacheRef)
        guard let cache = cacheRef else { throw RenderError.setup("texture cache") }
        let targets = try renderer.makeTargets(width: w, height: h)
        let scale = Double(w) / Double(cw)
        let timescale = Int32((fps * 1000).rounded())

        for i in 0..<frames {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw writer.error ?? RenderError.setup("writer failed") }
                usleep(500)
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw writer.error ?? RenderError.setup("no pixel buffer pool")
            }
            var pbRef: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbRef)
            guard let pb = pbRef else { throw RenderError.setup("pixel buffer") }
            var cvTex: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, Renderer.outFormat, w, h, 0, &cvTex)
            guard let cvTex, let tex = CVMetalTextureGetTexture(cvTex), let cb = renderer.queue.makeCommandBuffer()
            else {
                throw RenderError.setup("metal texture from pixel buffer")
            }
            renderer.encode(
                scene: scene, project: project, assets: assets, time: Double(i) / fps, scale: scale,
                transparent: transparent, commandBuffer: cb, targets: targets, output: tex)
            cb.commit()
            cb.waitUntilCompleted()
            if transparent {
                CVBufferSetAttachment(
                    pb, kCVImageBufferAlphaChannelModeKey, kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
                    .shouldPropagate)
            }
            guard adaptor.append(pb, withPresentationTime: CMTime(value: Int64(i) * 1000, timescale: timescale)) else {
                throw writer.error ?? RenderError.setup("append failed at frame \(i)")
            }
            progress?(i + 1, frames)
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.endSession(atSourceTime: CMTime(value: Int64(frames) * 1000, timescale: timescale))
        writer.finishWriting { done.signal() }
        done.wait()
        guard writer.status == .completed else { throw writer.error ?? RenderError.setup("export failed") }
        // Reference audio: mux into the finished video (video copied as-is).
        if let a = scene.audio, a.mute != true, !a.src.isEmpty {
            let tmp = url.deletingLastPathComponent().appendingPathComponent(
                ".\(url.lastPathComponent).audio.\(o.format.ext)")
            try SceneAudio.mux(
                video: url, audio: a, assets: assets, sceneDuration: Double(frames) / fps, output: tmp,
                fileType: o.format.fileType)
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: tmp, to: url)
        }
        return ExportResult(
            url: url, frames: frames, width: w, height: h, fps: fps, seconds: Date().timeIntervalSince(start))
    }

    /// A hand-edited project file can hold any number; the ones that become frame counts and pixel sizes are
    /// checked with the limits the CLI and MCP use, so a bad file fails with a clear error instead of a crash.
    static func checkNumbers(scene: Scene, project: Project, options o: ExportOptions) throws {
        let (w, h) = project.size(for: scene)
        _ = try SafeNumber.int(Double(w), "canvas width", in: 1...SafeNumber.maxCanvas)
        _ = try SafeNumber.int(Double(h), "canvas height", in: 1...SafeNumber.maxCanvas)
        _ = try SafeNumber.positive(o.fps ?? scene.fps ?? project.fps, "fps", max: SafeNumber.maxFPS)
        _ = try SafeNumber.positive(o.scale, "scale", max: SafeNumber.maxScale)
        // A duration of 0 or less exports one frame, as before (the validator reports it).
        if !(scene.duration <= 0) {
            _ = try SafeNumber.positive(scene.duration, "scene duration (seconds)", max: SafeNumber.maxDuration)
        }
    }

    /// Writes `<url without .png>_png/<scene>_00000.png …`. Motion blur and fades apply as in video export.
    func exportPNGSequence(
        scene: Scene, project: Project, assets: URL?, to url: URL, options o: ExportOptions,
        progress: ((Int, Int) -> Void)?
    ) throws -> ExportResult {
        let start = Date()
        let folder = url.deletingPathExtension().deletingPathExtension()
        let dir = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + "_png")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fps = o.fps ?? scene.fps ?? project.fps
        let frames = max(1, Int((scene.duration * fps).rounded(.up)))
        let saved = (renderer.draft, renderer.only)
        renderer.draft = false; renderer.only = nil
        defer { renderer.draft = saved.0; renderer.only = saved.1 }
        var size = (0, 0)
        for i in 0..<frames {
            let img = try renderer.image(
                scene: scene, project: project, assets: assets, time: Double(i) / fps,
                scale: o.scale, transparent: o.transparent ?? false)
            size = (img.width, img.height)
            try ImageFile.writePNG(img, to: dir.appendingPathComponent(String(format: "%@_%05d.png", scene.id, i)))
            progress?(i + 1, frames)
        }
        return ExportResult(
            url: dir, frames: frames, width: size.0, height: size.1, fps: fps, seconds: Date().timeIntervalSince(start))
    }

    /// One frame as a PNG (thumbnails, stills for posts).
    public func exportStill(
        scene: Scene, project: Project, assets: URL?, time: Double, to url: URL, scale: Double = 1,
        transparent: Bool = false
    ) throws -> URL {
        let saved = (renderer.draft, renderer.only)
        renderer.draft = false; renderer.only = nil
        defer { renderer.draft = saved.0; renderer.only = saved.1 }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let img = try renderer.image(
            scene: scene, project: project, assets: assets, time: time, scale: scale, transparent: transparent)
        try ImageFile.writePNG(img, to: url)
        return url
    }
}
