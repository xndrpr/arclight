import AVFoundation
import Foundation

/// Writing sound files into assets/ and keeping track of where they came from.
public enum AudioFiles {
    /// Formats the editor and exporter can read (Core Audio). Ogg/Opus aren't among them.
    public static let readable: Set<String> = ["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf", "flac"]
    static let maxBytes = 60 * 1024 * 1024

    /// A file extension for audio bytes, from their header (nil when Core Audio can't read them).
    public static func sniff(_ d: Data) -> String? {
        func at(_ o: Int, _ s: String) -> Bool {
            d.count >= o + s.count && d.subdata(in: o..<(o + s.count)) == Data(s.utf8)
        }
        if at(0, "RIFF") && at(8, "WAVE") { return "wav" }
        if at(0, "FORM") && (at(8, "AIFF") || at(8, "AIFC")) { return "aiff" }
        if at(0, "fLaC") { return "flac" }
        if at(0, "caff") { return "caf" }
        if at(4, "ftyp") { return "m4a" }
        if at(0, "ID3") { return "mp3" }
        if d.count > 2, d[0] == 0xFF, d[1] & 0xE0 == 0xE0 { return d[1] & 0x06 == 0 ? "aac" : "mp3" }
        return nil
    }

    /// A file-name base in plain Latin letters ("Привет, мир" → "privet-mir"), so names stay portable.
    public static func slug(_ s: String) -> String { Naming.slug(Naming.latin(s), maxWords: 4, fallback: "sound") }

    /// Writes audio bytes into assets/ as `base.ext` (or `base-2.ext`, …) after checking Core Audio can read them.
    /// Returns the file name.
    public static func write(_ data: Data, base: String, store: ProjectStore) throws -> String {
        guard data.count <= maxBytes else { throw ImageAIError.failed("the sound file is too big (over 60 MB)") }
        guard let ext = sniff(data) else {
            throw ImageAIError.failed("that isn't a sound file Arclight can play (wav, mp3, m4a, aiff, flac)")
        }
        let url = try freeName(base, ext: ext, store: store)
        try data.write(to: url, options: .atomic)
        guard let info = SceneAudio.info(url), info.duration > 0 else {
            try? FileManager.default.removeItem(at: url)
            throw ImageAIError.failed("the sound came back unreadable")
        }
        return url.lastPathComponent
    }

    /// A free `base.wav` name in assets/ (for writers that make the file themselves).
    static func freeName(_ base: String, ext: String = "wav", store: ProjectStore) throws -> URL {
        try FileManager.default.createDirectory(at: store.assetsURL, withIntermediateDirectories: true)
        return store.assetsURL.appendingPathComponent(Naming.freeFile(base, ext: ext, in: store.assetsURL))
    }

    /// Writes mono float samples as a 16-bit WAV.
    public static func writeWAV(_ samples: [Float], sampleRate: Double, to url: URL) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, samples.count)))
        else { throw ImageAIError.failed("audio buffer") }
        buf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buf.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buf)
    }

    /// Every frame of a file in its processing format. One `read(into:)` can stop short of the end, so this
    /// keeps reading until the file is exhausted.
    public static func readAll(_ f: AVAudioFile) throws -> AVAudioPCMBuffer? {
        let fmt = f.processingFormat
        let total = AVAudioFrameCount(max(0, f.length))
        guard total > 0, let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: total),
            let chunk = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: min(total, 1 << 16)),
            let dst = out.floatChannelData
        else { return nil }
        f.framePosition = 0
        var done: AVAudioFrameCount = 0
        while done < total {
            try f.read(into: chunk, frameCount: min(chunk.frameCapacity, total - done))
            let n = chunk.frameLength
            guard n > 0, let src = chunk.floatChannelData else { break }
            for c in 0..<Int(fmt.channelCount) { (dst[c] + Int(done)).update(from: src[c], count: Int(n)) }
            done += n
        }
        out.frameLength = done
        return done > 0 ? out : nil
    }

    /// Mono samples of a file (channels averaged), resampled to `rate` when given. For analysis.
    public static func mono(_ url: URL, rate: Double? = nil) throws -> (samples: [Float], rate: Double) {
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        guard let buf = try readAll(f) else { return ([], fmt.sampleRate) }
        let ch = Int(fmt.channelCount), len = Int(buf.frameLength)
        var out = [Float](repeating: 0, count: len)
        if let data = buf.floatChannelData {
            for c in 0..<ch {
                let p = data[c]
                for i in 0..<len { out[i] += p[i] / Float(ch) }
            }
        }
        guard let rate, rate < fmt.sampleRate else { return (out, fmt.sampleRate) }
        // Box-filter downsample: plenty for envelopes and onsets.
        let step = fmt.sampleRate / rate
        let m = Int(Double(len) / step)
        var down = [Float](repeating: 0, count: m)
        for i in 0..<m {
            let a = Int(Double(i) * step), b = min(len, Int(Double(i + 1) * step))
            var s: Float = 0
            for j in a..<max(a + 1, b) where j < len { s += out[j] }
            down[i] = s / Float(max(1, b - a))
        }
        return (down, rate)
    }

    // MARK: Credits

    /// Where a sound came from and how it may be used, kept in `assets/CREDITS.md` so the user can put the
    /// attribution in a video description (CC BY needs it).
    public static func credit(_ store: ProjectStore, asset: String, line: String) {
        let u = store.assetsURL.appendingPathComponent("CREDITS.md")
        var s =
            (try? String(contentsOf: u, encoding: .utf8))
            ?? "# Credits\n\nSounds and music from other people used in this project. Credit them where the video is published.\n\n"
        let entry = "- \(asset): \(line)\n"
        guard !s.contains(entry) else { return }
        if !s.hasSuffix("\n") { s += "\n" }
        s += entry
        try? s.write(to: u, atomically: true, encoding: .utf8)
    }
}
