import Accelerate
import Foundation

/// What's in a sound file, in times an agent can animate to: tempo and beats (music), onsets (hits, every new
/// sound), phrases between pauses (voiceover lines), loudness and the loudest moment.
public struct AudioAnalysis: Equatable, Sendable {
    public var duration: Double
    /// Peak and average (RMS) level, dBFS.
    public var peakDB: Double
    public var rmsDB: Double
    /// Beats per minute when the file has a steady pulse, else nil.
    public var bpm: Double?
    /// Beat times (s) when there is a tempo.
    public var beats: [Double]
    /// Times (s) where a new sound starts, strongest first is not implied: in time order.
    public var onsets: [Double]
    /// Stretches of sound between pauses (s): voiceover sentences, musical phrases.
    public var phrases: [ClosedRange<Double>]
    /// Time of the loudest 0.5 s (the drop, the shout).
    public var loudest: Double
    /// Level per second, 0…1 (relative to the loudest second), for a quick sense of the shape.
    public var energy: [Double]

    static let rate = 22050.0
    static let frame = 1024
    static let hop = 256

    public static func analyze(_ url: URL) throws -> AudioAnalysis {
        let (x, sr) = try AudioFiles.mono(url, rate: rate)
        return analyze(samples: x, sampleRate: sr)
    }

    public static func analyze(samples x: [Float], sampleRate sr: Double) -> AudioAnalysis {
        let duration = Double(x.count) / sr
        let peak = x.reduce(Float(0)) { max($0, abs($1)) }
        var ms: Float = 0
        if !x.isEmpty { vDSP_measqv(x, 1, &ms, vDSP_Length(x.count)) }
        func db(_ v: Double) -> Double { v > 1e-9 ? 20 * log10(v) : -120 }

        // Short-time RMS (10 ms) for pauses and loudness.
        let win = max(1, Int(sr * 0.01))
        var rms: [Double] = []
        var i = 0
        while i < x.count {
            let n = min(win, x.count - i)
            var m: Float = 0
            x.withUnsafeBufferPointer { vDSP_measqv($0.baseAddress! + i, 1, &m, vDSP_Length(n)) }
            rms.append(Double(m).squareRoot())
            i += win
        }
        let flux = onsetStrength(x, sr: sr)
        let fps = sr / Double(hop)
        let onsets = pickPeaks(flux, fps: fps)
        let (bpm, beats) = tempo(flux, fps: fps, duration: duration, onsets: onsets)

        // Loudest half second.
        var loudest = 0.0, best = -1.0
        let span = 50
        if rms.count > 0 {
            var acc = 0.0
            for k in 0..<rms.count {
                acc += rms[k] * rms[k]
                if k >= span { acc -= rms[k - span] * rms[k - span] }
                if acc > best { best = acc; loudest = Double(max(0, k - span / 2)) * 0.01 }
            }
        }
        // Energy per second.
        var energy: [Double] = []
        for s in stride(from: 0, to: rms.count, by: 100) {
            let part = rms[s..<min(rms.count, s + 100)]
            energy.append((part.map { $0 * $0 }.reduce(0, +) / Double(part.count)).squareRoot())
        }
        let emax = energy.max() ?? 0
        if emax > 0 { energy = energy.map { (($0 / emax) * 100).rounded() / 100 } }

        return AudioAnalysis(
            duration: duration, peakDB: (db(Double(peak)) * 10).rounded() / 10,
            rmsDB: (db(Double(ms).squareRoot()) * 10).rounded() / 10, bpm: bpm, beats: beats, onsets: onsets,
            phrases: phrases(rms, step: 0.01, peak: Double(peak)), loudest: (loudest * 100).rounded() / 100,
            energy: energy)
    }

    /// Spectral flux: how much new energy appears in each hop (log magnitudes, positive changes only).
    static func onsetStrength(_ x: [Float], sr: Double) -> [Double] {
        guard x.count > frame, let dft = vDSP.DFT(count: frame, direction: .forward, transformType: .complexComplex, ofType: Float.self)
        else { return [] }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: frame, isHalfWindow: false)
        var prev = [Float](repeating: 0, count: frame / 2)
        var out: [Double] = []
        let zeros = [Float](repeating: 0, count: frame)
        var start = 0
        while start + frame <= x.count {
            let seg = vDSP.multiply(Array(x[start..<(start + frame)]), window)
            var re = [Float](repeating: 0, count: frame), im = [Float](repeating: 0, count: frame)
            dft.transform(inputReal: seg, inputImaginary: zeros, outputReal: &re, outputImaginary: &im)
            var f = 0.0
            for b in 1..<(frame / 2) {
                let mag = log1p(10 * (re[b] * re[b] + im[b] * im[b]).squareRoot())
                let d = mag - prev[b]
                if d > 0 { f += Double(d) }
                prev[b] = mag
            }
            out.append(f)
            start += hop
        }
        // Remove the slow trend so loud passages don't count as one long onset.
        let w = 16
        var smooth = out
        for k in out.indices {
            let a = max(0, k - w), b = min(out.count, k + w + 1)
            smooth[k] = max(0, out[k] - out[a..<b].reduce(0, +) / Double(b - a))
        }
        return smooth
    }

    /// Local maxima clearly above their surroundings, at least 70 ms apart.
    static func pickPeaks(_ f: [Double], fps: Double) -> [Double] {
        guard let mx = f.max(), mx > 0 else { return [] }
        let gap = Int(0.07 * fps)
        let mean = f.reduce(0, +) / Double(f.count)
        let sd = (f.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(f.count)).squareRoot()
        let threshold = max(mean + 1.5 * sd, mx * 0.12)
        var out: [Double] = []
        var last = -gap
        // The edges count as silence, so a file that starts on a hit has an onset at 0.
        for k in f.indices where f[k] >= threshold && f[k] >= (k > 0 ? f[k - 1] : 0)
            && f[k] > (k + 1 < f.count ? f[k + 1] : 0)
        {
            if k - last < gap { continue }
            out.append((Double(k) / fps * 1000).rounded() / 1000)
            last = k
        }
        return out
    }

    /// Tempo from the autocorrelation of the onset strength (60–180 BPM, leaning to ~115), then a beat grid at the
    /// phase that lands on the most onset energy, each beat nudged to the nearest strong onset.
    static func tempo(_ f: [Double], fps: Double, duration: Double, onsets: [Double]) -> (Double?, [Double]) {
        // A pulse needs enough hits to be one (a voiceover's few word starts aren't).
        guard duration >= 4, f.count > Int(fps * 3), Double(onsets.count) >= max(6, duration * 0.8) else {
            return (nil, [])
        }
        let minLag = Int(fps * 60 / 180), maxLag = Int(fps * 60 / 60)
        guard maxLag < f.count / 2 else { return (nil, []) }
        var bestLag = 0, bestScore = 0.0, scores: [Double] = []
        let energy = f.map { $0 * $0 }.reduce(0, +)
        guard energy > 0 else { return (nil, []) }
        for lag in minLag...maxLag {
            var s = 0.0
            for k in 0..<(f.count - lag) { s += f[k] * f[k + lag] }
            let bpm = 60 * fps / Double(lag)
            let prior = exp(-0.5 * pow(log2(bpm / 115) / 0.9, 2))
            let v = s / energy * prior
            scores.append(s / energy)
            if v > bestScore { bestScore = v; bestLag = lag }
        }
        // A real pulse stands out from the average lag; speech and noise don't.
        let avg = scores.reduce(0, +) / Double(scores.count)
        guard bestLag > 0, scores[bestLag - minLag] > avg * 1.35 else { return (nil, []) }
        let period = Double(bestLag)
        var bestPhase = 0, bestSum = -1.0
        for ph in 0..<bestLag {
            var s = 0.0, k = Double(ph)
            while Int(k) < f.count { s += f[Int(k)]; k += period }
            if s > bestSum { bestSum = s; bestPhase = ph }
        }
        var beats: [Double] = []
        var k = Double(bestPhase)
        let r = Int(period * 0.1)
        while Int(k) < f.count {
            let c = Int(k)
            var at = c
            for j in max(0, c - r)...min(f.count - 1, c + r) where f[j] > f[at] { at = j }
            beats.append((Double(at) / fps * 1000).rounded() / 1000)
            k += period
        }
        // Most beats must land on a real onset, or the "tempo" is just the spacing of a few sounds.
        let onBeat = beats.filter { b in onsets.contains { abs($0 - b) < 0.07 } }.count
        guard Double(onBeat) >= Double(beats.count) * 0.5 else { return (nil, []) }
        return ((60 * fps / period * 10).rounded() / 10, beats)
    }

    /// Runs of sound separated by ≥ 0.3 s quieter than 30 dB below the peak; runs under 0.15 s are dropped.
    static func phrases(_ rms: [Double], step: Double, peak: Double) -> [ClosedRange<Double>] {
        guard peak > 0 else { return [] }
        let floor = peak * pow(10, -30.0 / 20) * 0.5
        var out: [ClosedRange<Double>] = []
        var start: Int?, quiet = 0
        let minGap = Int(0.3 / step)
        for (k, v) in rms.enumerated() {
            if v > floor {
                if start == nil { start = k }
                quiet = 0
            } else if let s = start {
                quiet += 1
                if quiet >= minGap {
                    let e = k - quiet + 1
                    if Double(e - s) * step >= 0.15 { out.append(round2(Double(s) * step)...round2(Double(e) * step)) }
                    start = nil; quiet = 0
                }
            }
        }
        if let s = start {
            let e = rms.count - quiet
            if Double(e - s) * step >= 0.15 { out.append(round2(Double(s) * step)...round2(Double(e) * step)) }
        }
        return out
    }

    public static func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }

    /// A short text report for agents.
    public var summary: String {
        var lines = [
            "duration \(Format.number(Self.round2(duration)))s, peak \(Format.number(peakDB)) dBFS, average \(Format.number(rmsDB)) dBFS, loudest at \(Format.number(loudest))s"
        ]
        if let bpm {
            lines.append(
                "tempo \(Format.number(bpm)) BPM (beat every \(Format.number((60 / bpm * 1000).rounded() / 1000))s), \(beats.count) beats: "
                    + list(beats, max: 32))
        } else {
            lines.append("no steady tempo (speech, effects or free-time music)")
        }
        lines.append("onsets (\(onsets.count)): " + list(onsets, max: 40))
        lines.append(
            "phrases between pauses (\(phrases.count)): "
                + phrases.prefix(24).map { "\(Format.number($0.lowerBound))–\(Format.number($0.upperBound))" }.joined(separator: ", ")
                + (phrases.count > 24 ? ", …" : ""))
        lines.append("energy per second (0–1): " + energy.prefix(60).map { Format.number($0) }.joined(separator: " "))
        return lines.joined(separator: "\n")
    }

    private func list(_ ts: [Double], max: Int) -> String {
        ts.prefix(max).map { Format.number($0) }.joined(separator: ", ") + (ts.count > max ? ", …" : "")
    }
}
