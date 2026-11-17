import Accelerate
import Foundation

/// What a sound is like, in numbers an agent can act on without hearing it: how loud, how bright, where its
/// energy sits, how fast it starts and how long it rings.
public struct AudioDescriptors: Equatable, Sendable {
    public var duration: Double
    /// Integrated loudness (LUFS) and the loudest 0.4 s.
    public var lufs: Double
    public var momentaryMax: Double
    public var truePeakDB: Double
    /// Peak minus loudness: high = spiky (clicks, hits), low = dense (pads, compressed music).
    public var crest: Double
    /// Spectral centroid (Hz): the "centre of gravity" of the spectrum, heard as brightness.
    public var centroid: Double
    /// Share of energy per band, 0…1: below 80 Hz, 80–250, 250–2k, 2–5k, 5–10k, above 10k.
    public var bands: [Double]
    /// The strongest steady tone (Hz) when the sound is tonal.
    public var tone: Double?
    /// Seconds of near-silence before the sound starts.
    public var lead: Double
    /// Time from the start of the sound to most of its peak level (ms), and from the peak down 20 dB (ms).
    /// Nil for long files, where they say little.
    public var attackMs: Double?
    public var decayMs: Double?
    /// The file starts or ends mid-wave (a click when played), or has flat-topped samples.
    public var abruptStart: Bool
    public var abruptEnd: Bool
    public var clipped: Bool

    public static let bandNames = ["sub <80", "bass 80–250", "mid 250–2k", "presence 2–5k", "high 5–10k", "air >10k"]
    static let bandEdges: [Double] = [80, 250, 2000, 5000, 10000]

    public static func measure(_ url: URL) throws -> AudioDescriptors { measure(try Stereo.read(url)) }

    public static func measure(_ s: Stereo) -> AudioDescriptors {
        let k = Loudness.kWeighted(s)
        let lufs = Loudness.integrated(k)
        let momentary = Loudness.windows(k, window: 0.4).max() ?? -120
        let tp = Loudness.truePeak(s)
        let mono = s.mono
        let (centroid, bands, tone) = spectrum(mono)

        // 2 ms peak envelope.
        let win = 96
        var env: [Float] = []
        var i = 0
        while i < s.count {
            let n = min(win, s.count - i)
            var a: Float = 0, b: Float = 0
            s.l.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress! + i, 1, &a, vDSP_Length(n)) }
            s.r.withUnsafeBufferPointer { vDSP_maxmgv($0.baseAddress! + i, 1, &b, vDSP_Length(n)) }
            env.append(max(a, b))
            i += win
        }
        let peak = env.max() ?? 0
        let step = Double(win) / Stereo.rate
        let first = env.firstIndex { $0 >= peak * 0.01 } ?? 0
        var attack: Double?, decay: Double?
        if peak > 0, s.duration <= 12 {
            let rise = env[first...].firstIndex { $0 >= peak * 0.7 } ?? first
            attack = Double(rise - first) * step * 1000
            let top = env.firstIndex(of: peak) ?? first
            let last = env.lastIndex { $0 >= peak * 0.1 } ?? top
            decay = Double(max(0, last - top)) * step * 1000
        }
        func edge(_ x: ArraySlice<Float>) -> Bool { (x.map { abs($0) }.max() ?? 0) > max(0.05, peak * 0.2) }
        var run = 0, clipped = false
        for ch in [s.l, s.r] where !clipped {
            for v in ch {
                run = abs(v) >= 0.999 ? run + 1 : 0
                if run >= 3 { clipped = true; break }
            }
        }
        func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
        return AudioDescriptors(
            duration: s.duration, lufs: r1(lufs), momentaryMax: r1(momentary), truePeakDB: r1(tp.db),
            crest: r1(tp.db - momentary), centroid: centroid.rounded(), bands: bands, tone: tone,
            lead: (Double(first) * step * 1000).rounded() / 1000, attackMs: attack.map { $0.rounded() },
            decayMs: decay.map { $0.rounded() }, abruptStart: edge(s.l.prefix(4)) || edge(s.r.prefix(4)),
            abruptEnd: edge(s.l.suffix(4)) || edge(s.r.suffix(4)), clipped: clipped)
    }

    /// Average power spectrum of the sounding parts → centroid, band shares and the strongest steady tone.
    static func spectrum(_ x: [Float]) -> (centroid: Double, bands: [Double], tone: Double?) {
        let frame = 4096
        var bands = [Double](repeating: 0, count: bandEdges.count + 1)
        var padded = x
        if padded.count < frame { padded += [Float](repeating: 0, count: frame - padded.count) }
        guard
            let dft = vDSP.DFT(count: frame, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        else { return (0, bands, nil) }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frame, isHalfWindow: false)
        let zeros = [Float](repeating: 0, count: frame)
        var power = [Double](repeating: 0, count: frame / 2)
        var frames: [[Float]] = []
        var energies: [Float] = []
        var start = 0
        while start + frame <= padded.count {
            let seg = Array(padded[start..<(start + frame)])
            frames.append(seg)
            energies.append(vDSP.meanSquare(seg))
            start += frame / 2
        }
        let floor = (energies.max() ?? 0) * 1e-5  // leave out frames 50 dB under the loudest
        for (seg, e) in zip(frames, energies) where e > floor {
            var re = [Float](repeating: 0, count: frame), im = [Float](repeating: 0, count: frame)
            dft.transform(inputReal: vDSP.multiply(seg, window), inputImaginary: zeros, outputReal: &re, outputImaginary: &im)
            for b in 0..<(frame / 2) { power[b] += Double(re[b] * re[b] + im[b] * im[b]) }
        }
        let hz = Stereo.rate / Double(frame)
        let total = power.reduce(0, +)
        guard total > 0 else { return (0, bands, nil) }
        var weighted = 0.0
        for b in 1..<(frame / 2) {
            let f = Double(b) * hz
            weighted += f * power[b]
            bands[bandEdges.firstIndex { f < $0 } ?? bandEdges.count] += power[b]
        }
        bands = bands.map { (($0 / total) * 100).rounded() / 100 }
        // Strongest peak between 40 Hz and 4 kHz; tonal when it carries a good part of the energy.
        let lo = Int(40 / hz), hi = Int(4000 / hz)
        var tone: Double?
        if let (b, p) = power[lo...hi].enumerated().max(by: { $0.element < $1.element }).map({ ($0.offset + lo, $0.element) }),
            b > 1
        {
            let around = power[(b - 2)...(b + 2)].reduce(0, +)
            if around / total > 0.2 {
                let a = power[b - 1], c = power[b + 1]
                let shift = (a - c) / (2 * (a - 2 * p + c))
                tone = ((Double(b) + (shift.isFinite ? shift : 0)) * hz * 10).rounded() / 10
            }
        }
        return (weighted / total, bands, tone)
    }

    /// "A3", "C#5": the nearest note to a frequency.
    public static func note(_ hz: Double) -> String {
        let n = Int((12 * log2(hz / 440)).rounded()) + 69
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[((n % 12) + 12) % 12])\(n / 12 - 1)"
    }

    /// The character in plain words, from the numbers.
    public var words: String {
        var w: [String] = []
        w.append(
            centroid < 500 ? "very dark" : centroid < 1200 ? "dark, warm" : centroid < 2500 ? "neutral"
                : centroid < 5000 ? "bright" : "very bright, thin")
        if bands[0] > 0.3 { w.append("sub-heavy (little of it survives phone speakers)") }
        if bands[3] > 0.3 { w.append("a lot of 2–5 kHz (the harsh zone)") }
        if let a = attackMs { w.append(a < 6 ? "sharp attack" : a < 30 ? "quick attack" : a < 120 ? "soft attack" : "slow swell") }
        if let d = decayMs { w.append(d < 120 ? "short" : d < 600 ? "medium tail" : "long tail") }
        if crest > 18 { w.append("spiky") } else if crest < 8 { w.append("dense") }
        return w.joined(separator: ", ")
    }

    /// Things that will be heard as faults.
    public var faults: [String] {
        var f: [String] = []
        if clipped { f.append("clipped (flat-topped samples)") }
        if truePeakDB > -0.1 { f.append("peaks at full scale — gain above 1 will distort") }
        if abruptStart { f.append("starts mid-wave: add fadeIn 0.01") }
        if abruptEnd { f.append("ends mid-wave: add fadeOut 0.02 or more") }
        if lead > 0.05 { f.append("\(Format.number(lead))s of silence before it starts: set trim \(Format.number(lead)) or place it that much earlier") }
        return f
    }

    /// A short report for agents.
    public var summary: String {
        var lines = [
            "loudness \(Format.number(lufs)) LUFS (loudest 0.4s \(Format.number(momentaryMax))), true peak \(Format.number(truePeakDB)) dBTP",
            "character: \(words)",
            "brightness (centroid) \(Format.number(centroid)) Hz"
                + (tone.map { "; strongest tone \(Format.number($0)) Hz (\(Self.note($0)))" } ?? "; no steady tone (noise or mixed)"),
            "energy: " + zip(Self.bandNames, bands).map { "\($0) \(Int(($1 * 100).rounded()))%" }.joined(separator: ", "),
        ]
        if let a = attackMs, let d = decayMs {
            lines.append("attack \(Format.number(a)) ms, decay \(Format.number(d)) ms, sound starts at \(Format.number(lead))s in the file")
        }
        if !faults.isEmpty { lines.append("faults: " + faults.joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }

    /// One line, for tools that report a new sound.
    public var line: String {
        "\(Format.number(lufs)) LUFS, peak \(Format.number(truePeakDB)) dBTP, \(words)"
            + (tone.map { ", tone \(Self.note($0))" } ?? "") + (faults.isEmpty ? "" : " — " + faults.joined(separator: "; "))
    }
}
