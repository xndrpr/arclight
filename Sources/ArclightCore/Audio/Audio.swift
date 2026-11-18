import AVFoundation
import Foundation

/// Reference audio: file info, waveform peaks for the timeline, and muxing into exported video.
public enum SceneAudio {
    /// Resolves `audio.src` against the project's assets folder (absolute paths allowed).
    /// With effects set (`pitch`, `rate`, filters, `reverb`, `reverse`) this is the processed copy (rendered on first use; the original if that fails).
    public static func url(_ a: AudioRef, assets: URL?) -> URL {
        let src = AssetPath.url(a.src, assets: assets)
        guard let fx = ClipFX(a), FileManager.default.fileExists(atPath: src.path) else { return src }
        return fx.processed(src) ?? src
    }

    public struct Info: Equatable, Sendable {
        public var duration: Double
        public var sampleRate: Double
        public var channels: Int
    }

    public static func info(_ url: URL) -> Info? {
        guard let f = try? AVAudioFile(forReading: url) else { return nil }
        let fmt = f.processingFormat
        return Info(
            duration: Double(f.length) / fmt.sampleRate, sampleRate: fmt.sampleRate, channels: Int(fmt.channelCount))
    }

    /// Works out `speech` ahead of the first Play (it decodes the whole voice file), off the main thread.
    public static func warm(_ scene: Scene, assets: URL?) {
        DispatchQueue.global(qos: .utility).async { _ = speech(scene, assets: assets) }
    }

    private static var speechCache: [String: [ClosedRange<Double>]] = [:]

    /// When the scene audio is speaking (its phrases between pauses, in scene time) — what `duck` follows.
    /// Empty unless some clip ducks.
    public static func speech(_ scene: Scene, assets: URL?) -> [ClosedRange<Double>] {
        guard let a = scene.audio, a.mute != true, (scene.sounds ?? []).contains(where: { ($0.duck ?? 0) > 0 && $0.mute != true })
        else { return [] }
        let u = url(a, assets: assets)
        let stamp = FileStamp.of(u.path)
        let key = "\(u.path)|\(stamp)"
        lock.lock()
        var phrases = speechCache[key]
        lock.unlock()
        if phrases == nil {
            guard let r = try? AudioAnalysis.analyze(u) else { return [] }
            phrases = r.phrases
            lock.lock(); speechCache[key] = r.phrases; lock.unlock()
        }
        guard let dur = info(u)?.duration else { return [] }
        let clip = AudioClip(a, fileDuration: dur, sceneDuration: scene.duration)
        let shift = clip.offset - clip.trim
        return (phrases ?? []).compactMap { p in
            let lo = max(clip.audibleStart, p.lowerBound + shift), hi = min(clip.audibleEnd, p.upperBound + shift)
            return hi > lo ? lo...hi : nil
        }
    }

    private static var peakCache: [String: [Float]] = [:]
    private static let lock = NSLock()

    /// Peak level (0…1) per bucket across the whole file, for drawing a waveform. Cached per file + size.
    public static func peaks(_ url: URL, buckets: Int) -> [Float] {
        let stamp = FileStamp.of(url.path)
        let key = "\(url.path)|\(stamp)|\(buckets)"
        lock.lock()
        if let p = peakCache[key] { lock.unlock(); return p }
        lock.unlock()
        guard buckets > 0, let f = try? AVAudioFile(forReading: url), f.length > 0 else { return [] }
        let fmt = f.processingFormat
        let total = f.length
        var peaks = [Float](repeating: 0, count: buckets)
        let chunk: AVAudioFrameCount = 65536
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { return [] }
        var pos: AVAudioFramePosition = 0
        while pos < total {
            buf.frameLength = 0
            guard (try? f.read(into: buf, frameCount: min(chunk, AVAudioFrameCount(total - pos)))) != nil,
                buf.frameLength > 0,
                let data = buf.floatChannelData
            else { break }
            let n = Int(buf.frameLength)
            for ch in 0..<Int(fmt.channelCount) {
                let p = data[ch]
                for i in 0..<n {
                    let b = min(buckets - 1, Int((Double(pos) + Double(i)) / Double(total) * Double(buckets)))
                    let v = abs(p[i])
                    if v > peaks[b] { peaks[b] = v }
                }
            }
            pos += AVAudioFramePosition(n)
        }
        lock.lock(); peakCache[key] = peaks; lock.unlock()
        return peaks
    }

    /// Runs async AVFoundation loading synchronously (exports run on a background thread).
    static func sync<T>(_ f: @escaping @Sendable () async throws -> T) throws -> T {
        let sem = DispatchSemaphore(value: 0)
        var result: Result<T, Error>!
        Task.detached {
            do { result = .success(try await f()) } catch { result = .failure(error) }; sem.signal()
        }
        sem.wait()
        return try result.get()
    }

    /// Where a clip lands in a scene: file seconds `fileStart…` play at scene time `at` for `length` seconds.
    /// The same placement the editor's timeline and playback use (`AudioClip`).
    public struct Placement: Equatable, Sendable {
        public var fileStart: Double
        public var at: Double
        public var length: Double
    }

    public static func placement(_ a: AudioRef, fileDuration: Double, sceneDuration: Double) -> Placement? {
        let trim = max(0, a.trim ?? 0)
        var start = trim, at = a.offset ?? 0
        if at < 0 { start -= at; at = 0 }
        var avail = fileDuration - start
        if let l = a.length { avail = min(avail, l - (start - trim)) }
        let length = min(avail, sceneDuration - at)
        return length > 0.01 ? Placement(fileStart: start, at: at, length: length) : nil
    }

    /// Writes `video` + the scene's audio into `output`. Video samples are copied as-is (no re-encode, alpha kept);
    /// audio is placed at `offset`, trimmed, gain/fades applied, cut at the scene end, and encoded as AAC.
    public static func mux(
        video: URL, audio a: AudioRef, assets: URL?, sceneDuration: Double, output: URL, fileType: AVFileType
    ) throws {
        _ = try mux(
            video: video, clips: [a], assets: assets, sceneDuration: sceneDuration, output: output, fileType: fileType)
    }

    /// Writes `video` + every clip (reference audio and sounds, mixed) into `output`. Returns false — and writes
    /// nothing — when no clip is heard inside the scene.
    @discardableResult
    public static func mux(
        video: URL, clips: [AudioRef], assets: URL?, sceneDuration: Double, output: URL, fileType: AVFileType
    ) throws -> Bool {
        let vAsset = AVURLAsset(url: video)
        let (vTrack, vFormat) = try sync { () -> (AVAssetTrack, CMFormatDescription?) in
            guard let v = try await vAsset.loadTracks(withMediaType: .video).first else {
                throw RenderError.setup("missing video track")
            }
            return (v, try await v.load(.formatDescriptions).first)
        }

        // Place every clip on its own composition track; the mix output sums them.
        let comp = AVMutableComposition()
        let ts: CMTimeScale = 48000
        func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: ts) }
        var tracks: [AVMutableCompositionTrack] = []
        var inputs: [AVMutableAudioMixInputParameters] = []
        for a in clips {
            let audioURL = url(a, assets: assets)
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                throw RenderError.setup("audio file not found: \(audioURL.path)")
            }
            let aAsset = AVURLAsset(url: audioURL)
            let (srcTrack, aDur) = try sync { () -> (AVAssetTrack, Double) in
                guard let s = try await aAsset.loadTracks(withMediaType: .audio).first else {
                    throw RenderError.setup("no audio in \(audioURL.lastPathComponent)")
                }
                return (s, try await aAsset.load(.duration).seconds)
            }
            guard let p = placement(a, fileDuration: aDur, sceneDuration: sceneDuration),
                let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try track.insertTimeRange(
                CMTimeRange(start: t(p.fileStart), duration: t(p.length)), of: srcTrack, at: t(p.at))
            let params = AVMutableAudioMixInputParameters(track: track)
            let gain = Float(a.gain ?? 1)
            params.setVolume(gain, at: .zero)
            if let fi = a.fadeIn, fi > 0 {
                params.setVolumeRamp(
                    fromStartVolume: 0, toEndVolume: gain,
                    timeRange: CMTimeRange(start: t(p.at), duration: t(min(fi, p.length))))
            }
            if let fo = a.fadeOut, fo > 0 {
                let f = min(fo, p.length)
                params.setVolumeRamp(
                    fromStartVolume: gain, toEndVolume: 0,
                    timeRange: CMTimeRange(start: t(p.at + p.length - f), duration: t(f)))
            }
            tracks.append(track)
            inputs.append(params)
        }
        guard !tracks.isEmpty else { return false }
        let mix = AVMutableAudioMix()
        mix.inputParameters = inputs

        let vReader = try AVAssetReader(asset: vAsset)
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        vReader.add(vOut)
        let aReader = try AVAssetReader(asset: comp)
        let aOut = AVAssetReaderAudioMixOutput(
            audioTracks: tracks,
            audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
        aOut.audioMix = mix
        aReader.add(aOut)

        try? FileManager.default.removeItem(at: output)
        let writer = try AVAssetWriter(outputURL: output, fileType: fileType)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: vFormat)
        vIn.expectsMediaDataInRealTime = false
        let aIn = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192_000,
            ])
        aIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn), writer.canAdd(aIn) else { throw RenderError.setup("writer rejected inputs") }
        writer.add(vIn); writer.add(aIn)
        guard vReader.startReading(), aReader.startReading(), writer.startWriting() else {
            throw writer.error ?? vReader.error ?? aReader.error ?? RenderError.setup("could not start mux")
        }
        writer.startSession(atSourceTime: .zero)

        let group = DispatchGroup()
        for (input, output, queue) in [
            (vIn, vOut as AVAssetReaderOutput, DispatchQueue(label: "arclight.mux.v")),
            (aIn, aOut as AVAssetReaderOutput, DispatchQueue(label: "arclight.mux.a")),
        ] {
            group.enter()
            var done = false
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData && !done {
                    if let sb = output.copyNextSampleBuffer() {
                        if !input.append(sb) { done = true; input.markAsFinished(); group.leave() }
                    } else {
                        done = true; input.markAsFinished(); group.leave()
                    }
                }
            }
        }
        group.wait()
        let sem = DispatchSemaphore(value: 0)
        writer.endSession(atSourceTime: CMTime(seconds: sceneDuration, preferredTimescale: 600))
        writer.finishWriting { sem.signal() }
        sem.wait()
        guard writer.status == .completed else { throw writer.error ?? RenderError.setup("mux failed") }
        return true
    }
}
