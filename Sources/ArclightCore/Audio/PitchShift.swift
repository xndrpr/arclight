import AVFoundation
import CryptoKit
import Foundation

/// Pitch-shifted copies of audio files for clips with `pitch` set. The shift keeps the length (time-stretch, not
/// varispeed), so trims, fades and placement line up with the original file. Rendered once per file + mtime +
/// pitch into `~/Library/Caches/Arclight/pitch` and reused by playback, waveforms and exports.
public enum PitchShift {
    /// Semitones the clip is shifted by, clamped to the range AVAudioUnitTimePitch supports; nil when unshifted.
    public static func semitones(_ a: AudioRef) -> Double? {
        guard let p = a.pitch, p.isFinite, abs(p) >= 0.01 else { return nil }
        return min(24, max(-24, p))
    }

    private static let lock = NSLock()
    private static var known: [String: URL] = [:]

    public static var cacheFolder: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(AppPaths.folderName).appendingPathComponent("pitch")
    }

    /// The shifted copy of `source` (rendered now if missing), or nil when it cannot be made.
    public static func shifted(_ source: URL, semitones: Double) -> URL? {
        let stamp =
            ((try? FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate]) as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(source.standardizedFileURL.path)|\(stamp)|\(String(format: "%.3f", semitones))"
        lock.lock()
        if let u = known[key], FileManager.default.fileExists(atPath: u.path) { lock.unlock(); return u }
        lock.unlock()
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let base = source.deletingPathExtension().lastPathComponent
        let out = cacheFolder.appendingPathComponent("\(base)-\(hash).caf")
        if !FileManager.default.fileExists(atPath: out.path) {
            do { try render(source, semitones: semitones, to: out) } catch { return nil }
        }
        lock.lock(); known[key] = out; lock.unlock()
        return out
    }

    /// Renders `source` through AVAudioUnitTimePitch offline; the output has exactly the source's frame count.
    public static func render(_ source: URL, semitones: Double, to out: URL) throws {
        let file = try AVAudioFile(forReading: source)
        let fmt = file.processingFormat
        let total = AVAudioFrameCount(file.length)
        guard total > 0 else { throw RenderError.setup("empty audio: \(source.lastPathComponent)") }

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let pitch = AVAudioUnitTimePitch()
        pitch.pitch = Float(semitones * 100)
        pitch.overlap = 16
        engine.attach(player)
        engine.attach(pitch)
        engine.connect(player, to: pitch, format: fmt)
        engine.connect(pitch, to: engine.mainMixerNode, format: fmt)
        let block: AVAudioFrameCount = 4096
        try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: block)
        try engine.start()
        defer { engine.stop() }
        player.scheduleFile(file, at: nil)
        player.play()

        // The time-pitch unit delays its output; skip that lead-in so the shifted copy stays in sync.
        let latency = Int((pitch.latency + engine.mainMixerNode.latency) * fmt.sampleRate)
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        let tmp = out.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        do {
            let writer = try AVAudioFile(
                forWriting: tmp, settings: fmt.settings, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
            guard let buf = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: block) else {
                throw RenderError.setup("pitch buffer")
            }
            var skip = latency, written = 0
            let wanted = Int(total)
            while written < wanted {
                let status = try engine.renderOffline(block, to: buf)
                guard status == .success else {
                    if status == .error { throw RenderError.setup("pitch render failed") }
                    continue
                }
                var from = 0, n = Int(buf.frameLength)
                if skip > 0 { let s = min(skip, n); from = s; n -= s; skip -= s }
                n = min(n, wanted - written)
                guard n > 0 else { continue }
                if from > 0 || n < Int(buf.frameLength) {
                    guard let part = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: AVAudioFrameCount(n)) else {
                        throw RenderError.setup("pitch buffer")
                    }
                    part.frameLength = AVAudioFrameCount(n)
                    let ch = Int(buf.format.channelCount)
                    if let src = buf.floatChannelData, let dst = part.floatChannelData {
                        let interleaved = buf.format.isInterleaved
                        let stride = interleaved ? ch : 1
                        for c in 0..<(interleaved ? 1 : ch) {
                            dst[c].update(from: src[c] + from * stride, count: n * stride)
                        }
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
