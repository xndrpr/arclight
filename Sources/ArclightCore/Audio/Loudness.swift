import AVFoundation
import Accelerate
import Foundation

/// Two channels of samples at 48 kHz: what analysis and the mix work on (mono files fill both channels).
public struct Stereo: Equatable, Sendable {
    public static let rate = 48000.0
    public var l: [Float]
    public var r: [Float]
    public init(l: [Float], r: [Float]) { self.l = l; self.r = r }
    public init(count: Int) { l = [Float](repeating: 0, count: count); r = l }
    public var count: Int { l.count }
    public var duration: Double { Double(count) / Self.rate }

    /// Reads a whole file as 48 kHz stereo.
    public static func read(_ url: URL) throws -> Stereo {
        let f = try AVAudioFile(forReading: url)
        let src = f.processingFormat
        guard let buf = try AudioFiles.readAll(f) else { return Stereo(count: 0) }
        let n = buf.frameLength
        var out = buf
        if src.sampleRate != rate {
            guard let dst = AVAudioFormat(standardFormatWithSampleRate: rate, channels: src.channelCount),
                let conv = AVAudioConverter(from: src, to: dst),
                let o = AVAudioPCMBuffer(
                    pcmFormat: dst, frameCapacity: AVAudioFrameCount(Double(n) * rate / src.sampleRate) + 4096)
            else { throw RenderError.setup("can't resample \(url.lastPathComponent)") }
            var fed = false
            var err: NSError?
            let status = conv.convert(to: o, error: &err) { _, st in
                if fed { st.pointee = .endOfStream; return nil }
                fed = true; st.pointee = .haveData; return buf
            }
            if status == .error { throw err ?? RenderError.setup("can't resample \(url.lastPathComponent)") }
            out = o
        }
        let len = Int(out.frameLength)
        guard let d = out.floatChannelData, len > 0 else { return Stereo(count: 0) }
        let left = Array(UnsafeBufferPointer(start: d[0], count: len))
        let right = out.format.channelCount > 1 ? Array(UnsafeBufferPointer(start: d[1], count: len)) : left
        return Stereo(l: left, r: right)
    }

    public var mono: [Float] { vDSP.multiply(0.5, vDSP.add(l, r)) }

    public var peak: Float { max(vDSP.maximumMagnitude(l), vDSP.maximumMagnitude(r)) }
}

/// Loudness the way broadcast meters measure it (ITU-R BS.1770): K-weighted, in LUFS, plus true peak.
public enum Loudness {
    /// The K-weighting filter (48 kHz): a high shelf then a high-pass, so level matches how loud it is heard.
    public static func kWeighted(_ s: Stereo) -> Stereo { Stereo(l: k(s.l), r: k(s.r)) }

    static func k(_ x: [Float]) -> [Float] {
        biquad(
            biquad(
                x, b: (1.53512485958697, -2.69169618940638, 1.19839281085285), a: (-1.69065929318241, 0.73248077421585)),
            b: (1, -2, 1), a: (-1.99004745483398, 0.99007225036621))
    }

    static func biquad(_ x: [Float], b: (Double, Double, Double), a: (Double, Double)) -> [Float] {
        var y = [Float](repeating: 0, count: x.count)
        var z1 = 0.0, z2 = 0.0
        for i in x.indices {
            let v = Double(x[i])
            let o = b.0 * v + z1
            z1 = b.1 * v - a.0 * o + z2
            z2 = b.2 * v - a.1 * o
            y[i] = Float(o)
        }
        return y
    }

    static func lufs(_ meanSquareSum: Double) -> Double {
        meanSquareSum > 1e-12 ? -0.691 + 10 * log10(meanSquareSum) : -120
    }

    /// Loudness of a stretch of K-weighted audio, ungated (LUFS).
    public static func level(_ k: Stereo, _ range: Range<Int>? = nil) -> Double {
        let r = (range ?? 0..<k.count).clamped(to: 0..<k.count)
        guard !r.isEmpty else { return -120 }
        return lufs(meanSquare(k.l, r) + meanSquare(k.r, r))
    }

    static func meanSquare(_ x: [Float], _ r: Range<Int>) -> Double {
        var m: Float = 0
        x.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + r.lowerBound, 1, &m, vDSP_Length(r.count)) }
        return Double(m)
    }

    /// Loudness of sliding windows (`window` s long, every 0.1 s) over K-weighted audio. A sound shorter than
    /// the window gives one value for all of it.
    public static func windows(_ k: Stereo, window: Double) -> [Double] {
        let w = Int(window * Stereo.rate), hop = Int(0.1 * Stereo.rate)
        guard k.count > w else { return k.count > 0 ? [level(k)] : [] }
        var out: [Double] = []
        var i = 0
        while i + w <= k.count { out.append(level(k, i..<(i + w))); i += hop }
        return out
    }

    /// Integrated loudness: the average of 0.4 s blocks, leaving out silence (below −70 LUFS) and passages more
    /// than 10 LU under the rest, as BS.1770 gates it.
    public static func integrated(_ k: Stereo) -> Double {
        let blocks = windows(k, window: 0.4).filter { $0 > -70 }
        guard !blocks.isEmpty else { return -120 }
        func mean(_ b: [Double]) -> Double {
            -0.691 + 10 * log10(b.map { pow(10, ($0 + 0.691) / 10) }.reduce(0, +) / Double(b.count))
        }
        let gate = mean(blocks) - 10
        let kept = blocks.filter { $0 > gate }
        return kept.isEmpty ? mean(blocks) : mean(kept)
    }

    private static let lock = NSLock()
    private static var fileCache: [String: Double] = [:]

    /// Integrated loudness of a whole file (cached per file + modification time); nil when unreadable.
    public static func integrated(file url: URL) -> Double? {
        let stamp =
            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(stamp)"
        lock.lock()
        if let v = fileCache[key] { lock.unlock(); return v }
        lock.unlock()
        guard let s = try? Stereo.read(url), s.count > 0 else { return nil }
        let v = integrated(kWeighted(s))
        lock.lock(); fileCache[key] = v; lock.unlock()
        return v
    }

    /// True peak (dBTP): the highest point of the waveform between samples too, found by 4× interpolation
    /// around the loudest samples. Also returns where it is (s).
    public static func truePeak(_ s: Stereo) -> (db: Double, at: Double) {
        let sample = s.peak
        guard sample > 0 else { return (-120, 0) }
        var best = sample, bestAt = 0
        let taps = 8
        // Windowed-sinc kernels for the three in-between positions.
        let kernels: [[Float]] = [0.25, 0.5, 0.75].map { frac in
            (-(taps - 1)...taps).map { j in
                let x = Double(j) - frac
                let sinc = x == 0 ? 1 : sin(.pi * x) / (.pi * x)
                let w = 0.5 + 0.5 * cos(.pi * x / Double(taps))
                return Float(sinc * w)
            }
        }
        for ch in [s.l, s.r] {
            let n = ch.count
            guard n > 2 * taps else { continue }
            for i in taps..<(n - taps) where abs(ch[i]) >= sample * 0.9 || abs(ch[i + 1]) >= sample * 0.9 {
                if abs(ch[i]) > best { best = abs(ch[i]); bestAt = i }
                for kern in kernels {
                    var v: Float = 0
                    for (j, c) in kern.enumerated() { v += c * ch[i - (taps - 1) + j] }
                    if abs(v) > best { best = abs(v); bestAt = i }
                }
            }
        }
        if best == sample {
            for ch in [s.l, s.r] { if let i = ch.firstIndex(where: { abs($0) == sample }) { bestAt = i; break } }
        }
        return (20 * log10(Double(best)), Double(bestAt) / Stereo.rate)
    }
}
