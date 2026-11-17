import Foundation

/// Motion-graphics sound effects made on the device from noise, filters and oscillators: free, instant, no key
/// and no licence to credit. Good for the everyday UI/motion sounds (whoosh, pop, click, riser, impact, chime…);
/// for anything realistic (a door, rain, a crowd) search the sound library or generate one.
public enum SoundSynth {
    public enum Preset: String, CaseIterable, Sendable {
        case whoosh, swipe, riser, reverse, impact, boom, hit, pop, click, tick, blip, beep, ding, chime, success,
            error, glitch, typing, sparkle, drop, bloop, sub, pad, bell

        public var about: String {
            switch self {
            case .whoosh: return "airy pass-by for moves and transitions (0.6–1.2 s)"
            case .swipe: return "short fast swish for slides and wipes (0.2–0.4 s)"
            case .riser: return "noise + rising tone that builds tension into a reveal (1–4 s)"
            case .reverse: return "reverse-cymbal swell that cuts off at its end (put the end on the hit) (1–2 s)"
            case .impact: return "deep cinematic hit with a tail, for titles landing (1–2 s)"
            case .boom: return "low sub drop, a big rumble (1.5–3 s)"
            case .hit: return "tight punchy thud for snaps and cuts (0.2–0.4 s)"
            case .pop: return "bubbly pop for things appearing (0.08–0.15 s)"
            case .click: return "UI click / button press (0.03–0.06 s)"
            case .tick: return "very short tick, e.g. counters or a clock (0.02 s)"
            case .blip: return "soft digital blip for icons and bullets (0.1 s)"
            case .beep: return "plain electronic beep (0.15–0.3 s)"
            case .ding: return "bright bell ding, notification (0.8–1.5 s)"
            case .chime: return "soft glassy chime with a long ring (1.5–2.5 s)"
            case .success: return "two rising notes: done / success (0.5 s)"
            case .error: return "two low buzzy notes: wrong / error (0.4 s)"
            case .glitch: return "digital stutter bursts (0.3–0.8 s)"
            case .typing: return "keyboard clatter for typing text on (as long as the text types)"
            case .sparkle: return "high twinkles, magic / shine (0.8–1.5 s)"
            case .drop: return "falling pitch sweep, e.g. something leaving (0.4–0.8 s)"
            case .bloop: return "round low water-drop 'bloop', a pure tone falling from ~420 to ~150 Hz, the pleasant bubble of product ads (0.12–0.25 s)"
            case .sub: return "soft sub thump felt more than heard, ~55 Hz, no click (0.5–1 s)"
            case .pad: return "warm dark sustained chord that swells in and out, a bed under a moment (2–8 s)"
            case .bell: return "soft low felt-mallet bell, warm, slow ring (1.5–3 s)"
            }
        }

        public var defaultDuration: Double {
            switch self {
            case .whoosh: return 0.8
            case .swipe: return 0.3
            case .riser: return 2
            case .reverse: return 1.5
            case .impact: return 1.5
            case .boom: return 2
            case .hit: return 0.3
            case .pop: return 0.12
            case .click: return 0.04
            case .tick: return 0.02
            case .blip: return 0.1
            case .beep: return 0.2
            case .ding: return 1.2
            case .chime: return 2
            case .success: return 0.55
            case .error: return 0.45
            case .glitch: return 0.5
            case .typing: return 1.5
            case .sparkle: return 1.2
            case .drop: return 0.6
            case .bloop: return 0.18
            case .sub: return 0.7
            case .pad: return 4
            case .bell: return 2.2
            }
        }
    }

    public static let sampleRate = 48000.0

    /// Samples (mono, peak about −1 dBFS). `pitch` in semitones shifts every tone and filter.
    /// `soft` 0…1 rounds the sound off: a slower attack and the highs rolled away (1 = very muffled and gentle).
    public static func render(
        _ p: Preset, duration: Double? = nil, pitch: Double = 0, seed: UInt64 = 1, soft: Double = 0
    ) -> [Float] {
        let raw = renderRaw(p, duration: duration, pitch: pitch, seed: seed)
        let s = min(1, max(0, soft))
        guard s > 0.001 else { return raw }
        // One-pole low-pass twice (12 dB/oct) from 12 kHz down to 500 Hz, plus an attack of up to 40 ms.
        let cutoff = 12000 * pow(500.0 / 12000, s)
        let a = Float(1 - exp(-2 * .pi * cutoff / sampleRate))
        var out = raw
        var z1: Float = 0, z2: Float = 0
        let attack = max(1, Int(s * 0.04 * sampleRate))
        for i in out.indices {
            z1 += a * (out[i] - z1); z2 += a * (z1 - z2)
            out[i] = z2 * (i < attack ? Float(i) / Float(attack) : 1)
        }
        return normalized(declick(out))
    }

    static func renderRaw(_ p: Preset, duration: Double? = nil, pitch: Double = 0, seed: UInt64 = 1) -> [Float] {
        let d = min(30, max(0.01, duration ?? p.defaultDuration))
        let sr = sampleRate
        let n = Int(d * sr)
        let k = pow(2, pitch / 12)
        var rng = SplitMix(seed: seed)
        var out = [Float](repeating: 0, count: n)
        func t(_ i: Int) -> Double { Double(i) / sr }
        func u(_ i: Int) -> Double { Double(i) / Double(max(1, n - 1)) }  // 0…1 through the sound

        switch p {
        case .whoosh, .swipe:
            // Band-passed noise; the band sweeps up and back as the "object" passes, loudest just after the middle.
            var f = SVF()
            let lo = (p == .swipe ? 900 : 350) * k, hi = (p == .swipe ? 5000 : 2600) * k
            for i in 0..<n {
                let x = u(i)
                let sweep = sin(.pi * min(1, x * 1.15))
                f.cutoff(lo + (hi - lo) * sweep, sr: sr, q: 2.2)
                let env = pow(sin(.pi * pow(x, 0.8)), 2.2)
                out[i] = Float(f.band(rng.noise()) * env)
            }
        case .riser:
            var f = SVF()
            var ph = 0.0, ph2 = 0.0
            for i in 0..<n {
                let x = u(i)
                f.cutoff((400 + 7000 * x * x) * k, sr: sr, q: 1.5)
                let freq = (110 * pow(8, x)) * k
                ph += freq / sr; ph2 += freq * 1.007 / sr
                let tone = (saw(ph) + saw(ph2)) * 0.25
                let env = pow(x, 1.6)
                out[i] = Float((f.band(rng.noise()) * 0.8 + tone * 0.6) * env)
            }
        case .reverse:
            var f = SVF()
            for i in 0..<n {
                let x = u(i)
                f.cutoff(9000 * k, sr: sr, q: 0.7)
                let env = pow(x, 3) * (x > 0.985 ? (1 - x) / 0.015 : 1)
                out[i] = Float(f.high(rng.noise()) * env)
            }
        case .impact, .boom, .hit:
            let big = p != .hit
            var ph = 0.0
            var f = SVF(), f2 = SVF()
            f2.cutoff(900 * k, sr: sr, q: 0.9)
            let decay = p == .boom ? 2.2 : p == .impact ? 3.5 : 18
            for i in 0..<n {
                let tt = t(i)
                let freq = (p == .boom ? 28 + 70 * exp(-tt * 6) : p == .impact ? 40 + 120 * exp(-tt * 14) : 70 + 180 * exp(-tt * 30)) * k
                ph += freq / sr
                let body = sin(2 * .pi * ph) * exp(-tt * decay)
                f.cutoff((big ? 2500 : 4000) * k, sr: sr, q: 0.8)
                let crack = f.low(rng.noise()) * exp(-tt * (big ? 25 : 60)) * (big ? 0.9 : 0.6)
                let tail = big ? f2.band(rng.noise()) * 0.12 * exp(-tt * 2.5) : 0
                out[i] = Float(tanh((body * 1.3 + crack + tail) * 1.4))
            }
        case .pop:
            var ph = 0.0
            for i in 0..<n {
                let x = u(i)
                let freq = (220 + 900 * exp(-x * 9)) * k
                ph += freq / sr
                out[i] = Float(sin(2 * .pi * ph) * pow(1 - x, 2.5) * min(1, t(i) / 0.002))
            }
        case .click, .tick:
            var f = SVF()
            var ph = 0.0
            for i in 0..<n {
                let tt = t(i)
                f.cutoff((p == .tick ? 6000 : 3000) * k, sr: sr, q: 3)
                ph += (p == .tick ? 3200 : 1800) * k / sr
                let env = exp(-tt * (p == .tick ? 900 : 250))
                out[i] = Float((f.band(rng.noise()) * 0.7 + sin(2 * .pi * ph) * 0.5) * env)
            }
        case .blip, .beep:
            var ph = 0.0
            let freq = (p == .blip ? 1320 : 880) * k
            for i in 0..<n {
                let x = u(i)
                ph += freq * (p == .blip ? 1 + 0.25 * (1 - x) : 1) / sr
                let shape = p == .blip ? sin(2 * .pi * ph) : tanh(sin(2 * .pi * ph) * 2.5) * 0.7
                let env = p == .blip ? pow(1 - x, 2) : min(1, t(i) / 0.005) * min(1, (1 - x) * 12)
                out[i] = Float(shape * env)
            }
        case .ding, .chime, .sparkle:
            // Bell partials (inharmonic), each decaying at its own rate.
            let partials: [(Double, Double, Double)] =
                p == .chime
                ? [(1, 1, 1.6), (2.76, 0.5, 2.4), (5.4, 0.25, 3.5), (8.93, 0.12, 5)]
                : [(1, 1, 3), (2.0, 0.6, 4), (3.01, 0.35, 6), (4.17, 0.2, 9), (5.43, 0.12, 12)]
            let strikes: [(at: Double, f: Double)]
            if p == .sparkle {
                var s: [(Double, Double)] = []
                var at = 0.0
                while at < d * 0.75 {
                    s.append((at, (1800 + rng.unit() * 2600) * k))
                    at += 0.04 + rng.unit() * 0.1
                }
                strikes = s
            } else {
                strikes = [(0, (p == .chime ? 1046.5 : 1568) * k)]
            }
            for s in strikes {
                let start = Int(s.at * sr)
                let amp = p == .sparkle ? 0.35 + rng.unit() * 0.3 : 1
                for i in start..<n {
                    let tt = t(i - start)
                    var v = 0.0
                    for (ratio, a, dec) in partials {
                        v += sin(2 * .pi * s.f * ratio * tt) * a * exp(-tt * dec * (p == .sparkle ? 3 : 1))
                    }
                    out[i] += Float(v * amp * min(1, tt / 0.001))
                }
            }
        case .success, .error:
            let notes: [Double] = p == .success ? [783.99, 1174.66] : [196, 174.6]
            let len = d / 2
            for (j, base) in notes.enumerated() {
                let start = Int(Double(j) * len * (p == .success ? 0.6 : 0.9) * sr)
                var ph = 0.0
                for i in start..<n {
                    let tt = t(i - start)
                    ph += base * k / sr
                    let wave =
                        p == .success
                        ? sin(2 * .pi * ph) + 0.3 * sin(4 * .pi * ph)
                        : tanh(saw(ph) * 3) * 0.6
                    let env = min(1, tt / 0.004) * exp(-tt * (p == .success ? 6 : 9))
                    out[i] += Float(wave * env)
                }
            }
        case .glitch:
            var i = 0
            while i < n {
                let len = Int((0.015 + rng.unit() * 0.06) * sr)
                let on = rng.unit() > 0.3
                let freq = (200 + rng.unit() * 2000) * k
                let crush = 1 + Int(rng.unit() * 24)
                var held = 0.0
                for j in 0..<min(len, n - i) where on {
                    if j % crush == 0 { held = rng.unit() > 0.5 ? rng.noise() : sin(2 * .pi * freq * t(j)) }
                    out[i + j] = Float(held * 0.8 * (1 - u(i + j) * 0.5))
                }
                i += len
            }
        case .typing:
            var at = 0.0
            while at < d - 0.02 {
                let start = Int(at * sr)
                let tone = (1500 + rng.unit() * 1500) * k
                var f = SVF()
                f.cutoff(tone, sr: sr, q: 4)
                let amp = 0.4 + rng.unit() * 0.6
                for j in 0..<Int(0.025 * sr) where start + j < n {
                    let tt = t(j)
                    out[start + j] += Float(f.band(rng.noise()) * amp * exp(-tt * 280))
                }
                at += 0.06 + rng.unit() * 0.11
            }
        case .drop:
            var ph = 0.0
            for i in 0..<n {
                let x = u(i)
                ph += (1400 * pow(0.06, x)) * k / sr
                out[i] = Float(sin(2 * .pi * ph) * (1 - x) * min(1, t(i) / 0.01))
            }
        case .bloop:
            // A pure tone that falls fast then settles, with a rounded attack: the "water drop" of motion ads.
            var ph = 0.0
            for i in 0..<n {
                let x = u(i)
                ph += (150 + 270 * exp(-x * 7)) * k / sr
                let env = min(1, t(i) / 0.014) * pow(1 - x, 1.6)
                out[i] = Float((sin(2 * .pi * ph) + 0.12 * sin(4 * .pi * ph)) * env)
            }
        case .sub:
            var ph = 0.0
            for i in 0..<n {
                let x = u(i)
                ph += (48 + 22 * exp(-x * 10)) * k / sr
                out[i] = Float(tanh(sin(2 * .pi * ph) * 1.4) * min(1, t(i) / 0.012) * pow(1 - x, 2))
            }
        case .pad:
            // A minor-ninth chord of slightly detuned sines, low-passed, swelling in and out.
            let notes = [110.0, 164.81, 220, 261.63, 329.63].map { $0 * k }
            var phases = [Double](repeating: 0, count: notes.count * 2)
            var f = SVF()
            f.cutoff(900 * k, sr: sr, q: 0.6)
            let edge = min(d * 0.4, 1.5)
            for i in 0..<n {
                var v = 0.0
                for (j, note) in notes.enumerated() {
                    phases[j * 2] += note / sr; phases[j * 2 + 1] += note * 1.004 / sr
                    v += (sin(2 * .pi * phases[j * 2]) + sin(2 * .pi * phases[j * 2 + 1])) / Double(j + 2)
                }
                let tt = t(i)
                let env = min(1, tt / edge) * min(1, (d - tt) / edge)
                out[i] = Float(f.low(v) * env * env)
            }
        case .bell:
            let base = 261.63 * k
            for i in 0..<n {
                let tt = t(i)
                var v = 0.0
                for (ratio, a, dec) in [(1.0, 1.0, 1.6), (2.0, 0.35, 2.6), (2.76, 0.18, 4.0), (4.07, 0.06, 7.0)] {
                    v += sin(2 * .pi * base * ratio * tt) * a * exp(-tt * dec)
                }
                out[i] = Float(v * min(1, tt / 0.012))
            }
        }
        return normalized(declick(out))
    }

    /// Renders a preset into assets/ as a WAV. Returns the file name.
    public static func write(
        _ p: Preset, duration: Double?, pitch: Double, seed: UInt64, soft: Double = 0, name: String?, store: ProjectStore
    ) throws -> String {
        let url = try AudioFiles.freeName(AudioFiles.slug(name ?? p.rawValue), store: store)
        try AudioFiles.writeWAV(render(p, duration: duration, pitch: pitch, seed: seed, soft: soft), sampleRate: sampleRate, to: url)
        ImageAI.log(store, op: "synth", model: "arclight", prompt: p.rawValue, source: nil, asset: url.lastPathComponent)
        return url.lastPathComponent
    }

    // MARK: DSP

    static func saw(_ ph: Double) -> Double { 2 * (ph - floor(ph)) - 1 }

    /// 2 ms fades at both ends so the clip never starts or stops with a click.
    static func declick(_ s: [Float]) -> [Float] {
        var s = s
        let m = min(s.count / 2, Int(0.002 * sampleRate))
        for i in 0..<m {
            let g = Float(i) / Float(max(1, m))
            s[i] *= g; s[s.count - 1 - i] *= g
        }
        return s
    }

    static func normalized(_ s: [Float]) -> [Float] {
        let peak = s.reduce(0) { max($0, abs($1)) }
        guard peak > 1e-6 else { return s }
        let g = 0.89 / peak
        return s.map { $0 * g }
    }

    /// State-variable filter (Chamberlin): low, band and high outputs from one state.
    struct SVF {
        var low = 0.0, bandState = 0.0
        var f = 0.1, q = 1.0
        mutating func cutoff(_ hz: Double, sr: Double, q res: Double) {
            f = 2 * sin(.pi * min(hz, sr / 6.5) / sr)
            q = 1 / max(0.5, res)
        }
        private mutating func step(_ x: Double) -> (Double, Double, Double) {
            low += f * bandState
            let high = x - low - q * bandState
            bandState += f * high
            return (low, bandState, high)
        }
        mutating func band(_ x: Double) -> Double { step(x).1 }
        mutating func low(_ x: Double) -> Double { step(x).0 }
        mutating func high(_ x: Double) -> Double { step(x).2 }
    }

    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// 0…1
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        /// −1…1
        mutating func noise() -> Double { unit() * 2 - 1 }
    }
}
