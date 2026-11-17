import AVFoundation
import CryptoKit
import Foundation

/// Per-clip effects (`pitch`, `rate`, `lowpass`, `highpass`, `reverb`, `reverse`), baked into a processed copy of
/// the file. The copy is rendered once per file + modification time + settings into
/// `~/Library/Caches/Arclight/fx` and used by playback, waveforms, analysis and exports alike, so they all agree.
/// Pitch and filters keep the length; `rate` stretches it; reverb adds its tail after the end.
public struct ClipFX: Equatable, Sendable {
    public var pitch = 0.0
    public var rate = 1.0
    public var lowpass: Double?
    public var highpass: Double?
    public var reverb = 0.0
    public var space = "hall"
    public var reverse = false

    public static let spaces = ["room", "hall", "plate", "cathedral"]

    /// The effects a clip asks for, clamped to what the audio units accept; nil when it asks for none.
    public init?(_ a: AudioRef) {
        if let p = a.pitch, p.isFinite, abs(p) >= 0.01 { pitch = min(24, max(-24, p)) }
        if let r = a.rate, r.isFinite, abs(r - 1) >= 0.005 { rate = min(4, max(0.25, r)) }
        if let f = a.lowpass, f.isFinite, f < 19000 { lowpass = max(40, f) }
        if let f = a.highpass, f.isFinite, f > 20 { highpass = min(12000, f) }
        if let r = a.reverb, r.isFinite, r > 0.005 { reverb = min(1, r) }
        if let s = a.space, Self.spaces.contains(s) { space = s }
        reverse = a.reverse == true
        if self == Self.none { return nil }
    }

    private init() {}
    private static let none = ClipFX()

    /// Seconds the reverb rings after the sound ends.
    public var tail: Double {
        guard reverb > 0 else { return 0 }
        switch space {
        case "room": return 1.0
        case "plate": return 2.0
        case "cathedral": return 6.0
        default: return 3.2
        }
    }

    var key: String {
        String(
            format: "p%.3f r%.3f lp%.0f hp%.0f rv%.3f %@ %@", pitch, rate, lowpass ?? 0, highpass ?? 0, reverb,
            reverb > 0 ? space : "-", reverse ? "rev" : "fwd")
    }

    private static let lock = NSLock()
    private static var known: [String: URL] = [:]

    public static var cacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppPaths.folderName).appendingPathComponent("fx")
    }

    /// The processed copy of `source` (rendered now if missing), or nil when it cannot be made.
    public func processed(_ source: URL) -> URL? {
        let stamp =
            ((try? FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate]) as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(source.standardizedFileURL.path)|\(stamp)|\(self.key)"
        Self.lock.lock()
        if let u = Self.known[key], FileManager.default.fileExists(atPath: u.path) { Self.lock.unlock(); return u }
        Self.lock.unlock()
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let base = source.deletingPathExtension().lastPathComponent
        let out = Self.cacheFolder.appendingPathComponent("\(base)-\(hash).caf")
        if !FileManager.default.fileExists(atPath: out.path) {
            do { try render(source, to: out) } catch { return nil }
        }
        Self.lock.lock(); Self.known[key] = out; Self.lock.unlock()
        return out
    }

    /// Renders `source` through the effect chain offline.
    public func render(_ source: URL, to out: URL) throws {
        let file = try AVAudioFile(forReading: source)
        let src = file.processingFormat
        guard let read = try AudioFiles.readAll(file) else {
            throw RenderError.setup("empty audio: \(source.lastPathComponent)")
        }
        let total = read.frameLength
        // Always process in stereo: the reverb unit refuses mono (and raises an exception Swift can't catch).
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: src.sampleRate, channels: 2),
            let input = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: total), let from = read.floatChannelData,
            let to = input.floatChannelData
        else { throw RenderError.setup("fx buffer") }
        let n = Int(read.frameLength)
        input.frameLength = read.frameLength
        let right = src.channelCount > 1 ? 1 : 0
        if reverse {
            for i in 0..<n { to[0][i] = from[0][n - 1 - i]; to[1][i] = from[right][n - 1 - i] }
        } else {
            to[0].update(from: from[0], count: n)
            to[1].update(from: from[right], count: n)
        }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        var chain: [AVAudioNode] = [player]
        var latency = 0.0
        if pitch != 0 || rate != 1 {
            let u = AVAudioUnitTimePitch()
            u.pitch = Float(pitch * 100)
            u.rate = Float(rate)
            u.overlap = 16
            chain.append(u)
        }
        if lowpass != nil || highpass != nil {
            // Two bands per filter: 24 dB per octave.
            let eq = AVAudioUnitEQ(numberOfBands: 4)
            for (i, band) in eq.bands.enumerated() {
                let f = i < 2 ? highpass : lowpass
                band.filterType = i < 2 ? .highPass : .lowPass
                band.frequency = Float(f ?? 1000)
                band.bypass = f == nil
            }
            chain.append(eq)
        }
        if reverb > 0 {
            let u = AVAudioUnitReverb()
            u.loadFactoryPreset(
                space == "room"
                    ? .mediumRoom : space == "plate" ? .plate : space == "cathedral" ? .cathedral : .largeHall)
            u.wetDryMix = Float(reverb * 100)
            chain.append(u)
        }
        for n in chain.dropFirst() { engine.attach(n) }
        chain.append(engine.mainMixerNode)
        for (a, b) in zip(chain, chain.dropFirst()) { engine.connect(a, to: b, format: fmt) }
        let block: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: block)
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(input, at: nil)
        player.play()
        // The time-pitch unit delays its output; skip that lead-in so the copy stays in sync.
        for n in chain { if let u = n as? AVAudioUnitTimePitch { latency += u.latency } }
        var skip = Int(latency * fmt.sampleRate)
        let wanted = Int(Double(total) / rate) + Int(tail * fmt.sampleRate)

        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = out.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            let writer = try AVAudioFile(
                forWriting: tmp, settings: fmt.settings, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
            guard let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block) else {
                throw RenderError.setup("fx buffer")
            }
            var written = 0, idle = 0
            while written < wanted {
                let status = try engine.renderOffline(block, to: buf)
                guard status == .success else {
                    idle += 1
                    if status == .error || idle > 1000 { throw RenderError.setup("fx render failed") }
                    continue
                }
                var from = 0, n = Int(buf.frameLength)
                if skip > 0 { let s = min(skip, n); from = s; n -= s; skip -= s }
                n = min(n, wanted - written)
                guard n > 0 else { continue }
                if from > 0 || n < Int(buf.frameLength) {
                    guard let part = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: AVAudioFrameCount(n)) else {
                        throw RenderError.setup("fx buffer")
                    }
                    part.frameLength = AVAudioFrameCount(n)
                    if let src = buf.floatChannelData, let dst = part.floatChannelData {
                        for c in 0..<Int(buf.format.channelCount) { dst[c].update(from: src[c] + from, count: n) }
                    }
                    try writer.write(from: part)
                } else {
                    try writer.write(from: buf)
                }
                written += n
            }
        }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: tmp, to: out)
    }
}
