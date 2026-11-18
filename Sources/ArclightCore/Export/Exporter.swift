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
        try export(scenes: [scene], project: project, assets: assets, to: url, options: o, progress: progress)
    }

    /// Several scenes played one after another into one file (video, or one PNG sequence), in the given order.
    /// Each scene keeps its own sound mix and loudness; the output takes the first scene's canvas and frame rate.
    /// The scenes must share an aspect ratio (a different size is scaled to fit the first).
    public func export(
        scenes: [Scene], project: Project, assets: URL?, to url: URL, options o: ExportOptions,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> ExportResult {
        guard let first = scenes.first else { throw RenderError.setup("no scenes to export") }
        // Export draws every layer at full quality, whatever the editor viewport left set (draft preview, solo).
        let saved = (renderer.draft, renderer.only)
        renderer.draft = false; renderer.only = nil
        defer { renderer.draft = saved.0; renderer.only = saved.1 }
        for sc in scenes { try Exporter.checkNumbers(scene: sc, project: project, options: o) }
        let (cw, ch) = project.size(for: first)
        for sc in scenes.dropFirst() {
            let (w, h) = project.size(for: sc)
            if abs(Double(w) / Double(h) - Double(cw) / Double(ch)) > 0.01 {
                throw RenderError.setup(
                    "can't join “\(sc.name ?? sc.id)” (\(w)×\(h)) after “\(first.name ?? first.id)” (\(cw)×\(ch)): "
                        + "the scenes have different shapes")
            }
        }
        let fps = o.fps ?? first.fps ?? project.fps
        // Frames per scene, and the frame each one starts at.
        let counts = scenes.map { max(1, Int(($0.duration * fps).rounded(.up))) }
        let frames = counts.reduce(0, +)
        func segment(_ i: Int) -> (scene: Scene, local: Int) {
            var k = i
            for (n, c) in counts.enumerated() {
                if k < c { return (scenes[n], k) }
                k -= c
            }
            return (scenes[scenes.count - 1], counts[counts.count - 1] - 1)
        }
        if o.format == .png {
            return try exportPNGSequence(
                name: scenes.count == 1 ? first.id : url.deletingPathExtension().lastPathComponent,
                frames: frames, segment: segment, fps: fps, project: project, assets: assets, to: url, options: o,
                progress: progress)
        }
        let start = Date()
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        let w = even(Double(cw) * o.scale), h = even(Double(ch) * o.scale)
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
        let timescale = Int32((fps * 1000).rounded())

        for i in 0..<frames {
            let (scene, local) = segment(i)
            let scale = Double(w) / Double(project.size(for: scene).0)
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
                scene: scene, project: project, assets: assets, time: Double(local) / fps, scale: scale,
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
        // Reference audio and sound clips: each scene's mix (the same one the editor plays and mix_check
        // measures, through its master limiter) laid end to end, then muxed into the finished video.
        if scenes.contains(where: { !$0.audibleClips.isEmpty }) {
            var mix = Stereo(count: 0)
            var any = false
            for (n, sc) in scenes.enumerated() {
                let len = Int((Double(counts[n]) / fps * Stereo.rate).rounded())
                var part = Stereo(count: len)
                if !sc.audibleClips.isEmpty {
                    let rendered = SceneMix.render(sc, assets: assets)
                    if !rendered.stems.isEmpty {
                        any = true
                        let m = SceneMix.master(rendered.mix, loudness: sc.loudness)
                        let k = min(len, m.count)
                        part.l.replaceSubrange(0..<k, with: m.l[..<k])
                        part.r.replaceSubrange(0..<k, with: m.r[..<k])
                    }
                }
                mix.l += part.l; mix.r += part.r
            }
            if any {
                let tmp = url.deletingLastPathComponent().appendingPathComponent(
                    ".\(url.lastPathComponent).audio.\(o.format.ext)")
                let wav = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).mix.wav")
                defer { try? FileManager.default.removeItem(at: wav) }
                try SceneMix.write(mix, to: wav)
                if try SceneAudio.mux(
                    video: url, clips: [AudioRef(src: wav.path)], assets: assets, sceneDuration: Double(frames) / fps,
                    output: tmp, fileType: o.format.fileType)
                {
                    try FileManager.default.removeItem(at: url)
                    try FileManager.default.moveItem(at: tmp, to: url)
                }
            }
        }
        return ExportResult(
            url: url, frames: frames, width: w, height: h, fps: fps, seconds: Date().timeIntervalSince(start))
    }

    /// File-name base for all scenes joined into one video: the project's name in plain Latin letters.
    public static func joinedName(_ projectName: String) -> String {
        // slug() falls back to "sound" when nothing usable is left.
        let base = AudioFiles.slug(projectName)
        return base == "sound" && !projectName.lowercased().contains("sound") ? "all-scenes" : base
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

    /// Writes `<url without .png>_png/<name>_00000.png …`. Motion blur and fades apply as in video export.
    func exportPNGSequence(
        name: String, frames: Int, segment: (Int) -> (scene: Scene, local: Int), fps: Double, project: Project,
        assets: URL?, to url: URL, options o: ExportOptions, progress: ((Int, Int) -> Void)?
    ) throws -> ExportResult {
        let start = Date()
        let folder = url.deletingPathExtension().deletingPathExtension()
        let dir = folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + "_png")
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let width = Double(project.size(for: segment(0).scene).0) * o.scale
        var size = (0, 0)
        for i in 0..<frames {
            let (scene, local) = segment(i)
            let img = try renderer.image(
                scene: scene, project: project, assets: assets, time: Double(local) / fps,
                scale: width / Double(project.size(for: scene).0), transparent: o.transparent ?? false)
            size = (img.width, img.height)
            try ImageFile.writePNG(img, to: dir.appendingPathComponent(String(format: "%@_%05d.png", name, i)))
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
