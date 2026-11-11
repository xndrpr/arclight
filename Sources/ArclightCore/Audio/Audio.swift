import AVFoundation
import Foundation

/// Reference audio: file info, waveform peaks for the timeline, and muxing into exported video.
public enum SceneAudio {
    /// Resolves `audio.src` against the project's assets folder (absolute paths allowed).
    public static func url(_ a: AudioRef, assets: URL?) -> URL {
        AssetPath.url(a.src, assets: assets)
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

    private static var peakCache: [String: [Float]] = [:]
    private static let lock = NSLock()

    /// Peak level (0…1) per bucket across the whole file, for drawing a waveform. Cached per file + size.
    public static func peaks(_ url: URL, buckets: Int) -> [Float] {
        let stamp =
            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)?
            .timeIntervalSince1970 ?? 0
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

    /// Writes `video` + the scene's audio into `output`. Video samples are copied as-is (no re-encode, alpha kept);
    /// audio is placed at `offset`, trimmed, gain/fades applied, cut at the scene end, and encoded as AAC.
    public static func mux(
        video: URL, audio a: AudioRef, assets: URL?, sceneDuration: Double, output: URL, fileType: AVFileType
    ) throws {
        let audioURL = url(a, assets: assets)
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw RenderError.setup("audio file not found: \(audioURL.path)")
        }
        let vAsset = AVURLAsset(url: video), aAsset = AVURLAsset(url: audioURL)
        let (vTrack, vFormat, srcTrack, aDur) = try sync {
            () -> (AVAssetTrack, CMFormatDescription?, AVAssetTrack, Double) in
            guard let v = try await vAsset.loadTracks(withMediaType: .video).first,
                let s = try await aAsset.loadTracks(withMediaType: .audio).first
            else { throw RenderError.setup("missing video or audio track") }
            let fd = try await v.load(.formatDescriptions).first
            let d = try await aAsset.load(.duration).seconds
            return (v, fd, s, d)
        }

        // Place the audio on a composition timeline.
        let comp = AVMutableComposition()
        guard let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw RenderError.setup("audio track") }
        let ts: CMTimeScale = 48000
        func t(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: ts) }
        var start = max(0, a.trim ?? 0), at = a.offset ?? 0
        if at < 0 { start -= at; at = 0 }
        let length = min(aDur - start, sceneDuration - at)
        if length > 0.01 {
            try track.insertTimeRange(CMTimeRange(start: t(start), duration: t(length)), of: srcTrack, at: t(at))
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        let gain = Float(a.gain ?? 1)
        params.setVolume(gain, at: .zero)
        if let fi = a.fadeIn, fi > 0 {
            params.setVolumeRamp(
                fromStartVolume: 0, toEndVolume: gain, timeRange: CMTimeRange(start: t(at), duration: t(fi)))
        }
        if let fo = a.fadeOut, fo > 0 {
            params.setVolumeRamp(
                fromStartVolume: gain, toEndVolume: 0,
                timeRange: CMTimeRange(start: t(max(0, sceneDuration - fo)), duration: t(fo)))
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]

        let vReader = try AVAssetReader(asset: vAsset)
        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: nil)
        vReader.add(vOut)
        let aReader = try AVAssetReader(asset: comp)
        let aOut = AVAssetReaderAudioMixOutput(
            audioTracks: [track],
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
    }
}
