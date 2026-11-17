import AVFoundation
import Foundation

/// The scene's sound rendered to samples: every clip placed, trimmed and faded exactly as the editor plays it and
/// the export mixes it, then summed. What `mix_check` measures.
public enum SceneMix {
    /// One clip as it is heard: its samples (gain and fades applied) from scene sample `start`.
    public struct Stem: Sendable {
        public var id: String
        public var ref: AudioRef
        public var clip: AudioClip
        public var start: Int
        public var audio: Stereo
        /// The scene's reference audio (voiceover or music), as opposed to a sound clip.
        public var isReference: Bool
        public var range: Range<Int> { start..<(start + audio.count) }
    }

    public struct Rendered: Sendable {
        public var stems: [Stem]
        public var mix: Stereo
        /// Files that could not be read (named in reports, left out of the mix).
        public var missing: [String]
    }

    public static func render(_ scene: Scene, assets: URL?) -> Rendered {
        var files: [URL: Stereo] = [:]
        var stems: [Stem] = []
        var missing: [String] = []
        let total = Int((scene.duration * Stereo.rate).rounded())
        var mix = Stereo(count: total)
        let speech = SceneAudio.speech(scene, assets: assets)
        var clips: [(AudioRef, Bool)] = []
        if let a = scene.audio { clips.append((a, true)) }
        clips += (scene.sounds ?? []).map { ($0, false) }
        for (ref, isRef) in clips where ref.mute != true && !ref.src.isEmpty {
            let url = SceneAudio.url(ref, assets: assets)
            if files[url] == nil { files[url] = try? Stereo.read(url) }
            guard let file = files[url], file.count > 0 else { missing.append(ref.src); continue }
            let clip = AudioClip(
                ref, fileDuration: file.duration, sceneDuration: scene.duration, speech: isRef ? [] : speech)
            let pan = clip.panGains
            let a = Int((clip.audibleStart * Stereo.rate).rounded())
            let b = min(total, Int((clip.audibleEnd * Stereo.rate).rounded()))
            guard b > a else { continue }
            var out = Stereo(count: b - a)
            let filePos = Int((clip.filePosition(at: clip.audibleStart) * Stereo.rate).rounded())
            for i in 0..<(b - a) {
                let j = filePos + i
                guard j >= 0, j < file.count else { continue }
                let g = Float(clip.envelope(at: Double(a + i) / Stereo.rate))
                out.l[i] = file.l[j] * g * Float(pan.l)
                out.r[i] = file.r[j] * g * Float(pan.r)
                mix.l[a + i] += out.l[i]
                mix.r[a + i] += out.r[i]
            }
            stems.append(
                Stem(id: isRef ? "audio" : (ref.id ?? ref.src), ref: ref, clip: clip, start: a, audio: out, isReference: isRef))
        }
        return Rendered(stems: stems, mix: mix, missing: missing)
    }
}

extension SceneMix {
    /// Sample-peak ceiling of the master limiter (leaves room for peaks between samples: about −1 dBTP).
    public static let ceiling = Float(pow(10, -1.5 / 20))

    /// The master bus: an optional gain to reach `loudness` (LUFS, at most +12 dB), then a look-ahead limiter
    /// so nothing leaves louder than the ceiling. Quiet mixes pass through untouched.
    public static func master(_ mix: Stereo, loudness: Double? = nil) -> Stereo {
        var out = mix
        if let target = loudness {
            let now = Loudness.integrated(Loudness.kWeighted(mix))
            if now > -70 {
                let g = Float(pow(10, min(12, target - now) / 20))
                out.l = vDSPScale(out.l, g); out.r = vDSPScale(out.r, g)
            }
        }
        let n = out.count
        guard n > 0, out.peak > ceiling else { return out }
        // Gain each sample needs, held over a 5 ms window either side and smoothed, so the limiter moves before
        // the peak arrives; then a slower recovery (about 80 ms) so it doesn't pump.
        let look = 240
        var need = [Float](repeating: 1, count: n)
        for i in 0..<n {
            let p = max(abs(out.l[i]), abs(out.r[i]))
            if p > ceiling { need[i] = ceiling / p }
        }
        var held = [Float](repeating: 1, count: n)
        var deque: [Int] = []
        var head = 0
        for i in 0..<(n + look) {
            if i < n {
                while deque.count > head, need[deque[deque.count - 1]] >= need[i] { deque.removeLast() }
                deque.append(i)
            }
            let centre = i - look
            guard centre >= 0 else { continue }
            while deque.count > head, deque[head] < centre - look { head += 1 }
            if deque.count > head { held[centre] = need[deque[head]] }
        }
        var gain = [Float](repeating: 1, count: n)
        var acc = 0.0
        for i in 0..<n {
            acc += Double(held[min(n - 1, i + look / 2)])
            if i >= look { acc -= Double(held[min(n - 1, i - look + look / 2)]) }
            gain[i] = i >= look - 1 ? Float(acc / Double(look)) : held[i]
            gain[i] = min(gain[i], need[i])
        }
        let release = Float(1 - exp(-1 / (0.08 * Stereo.rate)))
        var g: Float = 1
        for i in 0..<n {
            g = min(gain[i], g + (1 - g) * release)
            out.l[i] *= g; out.r[i] *= g
        }
        return out
    }

    private static func vDSPScale(_ x: [Float], _ g: Float) -> [Float] { x.map { $0 * g } }

    /// Writes samples as a 48 kHz stereo 24-bit WAV.
    public static func write(_ s: Stereo, to url: URL) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: Stereo.rate, channels: 2)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Stereo.rate, AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, s.count))) else {
            throw RenderError.setup("audio buffer")
        }
        buf.frameLength = AVAudioFrameCount(s.count)
        s.l.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: s.count) }
        s.r.withUnsafeBufferPointer { buf.floatChannelData![1].update(from: $0.baseAddress!, count: s.count) }
        try file.write(from: buf)
    }
}

extension SceneMix {
    /// A sound candidate rendered for listening, through the master like an export: on its own (`scene` nil),
    /// or in the scene's mix from 2 s before it to 1.5 s after, with the clips in `replace` left out. Returns a
    /// temporary WAV.
    public static func preview(_ clip: AudioRef, in scene: Scene?, replace: [String] = [], assets: URL?) throws -> URL {
        var c = clip
        var s: Scene
        var window: Range<Int>?
        if let scene {
            s = scene
            s.sounds = (s.sounds ?? []).filter { r in !replace.contains(r.id ?? "") }
            if replace.contains("audio") { s.audio = nil }
            c.id = "candidate"
            s.sounds?.append(c)
            let len = info(c, assets: assets)
            let from = max(0, (c.offset ?? 0) - 2), to = min(s.duration, (c.offset ?? 0) + len + 1.5)
            window = Int(from * Stereo.rate)..<Int(max(from + 0.1, to) * Stereo.rate)
        } else {
            c.offset = 0
            c.id = "candidate"
            s = Scene(id: "preview", duration: max(0.1, info(c, assets: assets)))
            s.sounds = [c]
        }
        let rendered = render(s, assets: assets)
        guard rendered.missing.isEmpty || !rendered.missing.contains(clip.src) else {
            throw RenderError.setup("'\(clip.src)' not found in assets/")
        }
        var mix = master(rendered.mix, loudness: nil)
        if let w = window?.clamped(to: 0..<mix.count), !w.isEmpty {
            mix = Stereo(l: Array(mix.l[w]), r: Array(mix.r[w]))
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-preview-\(UUID().uuidString).wav")
        try write(mix, to: url)
        return url
    }

    /// Seconds a clip plays for (its file after effects, trimmed and cut by `length`).
    static func info(_ c: AudioRef, assets: URL?) -> Double {
        let d = SceneAudio.info(SceneAudio.url(c, assets: assets))?.duration ?? 0
        return max(0, min(d - max(0, c.trim ?? 0), c.length ?? .infinity))
    }
}

/// How the scene's sound sits together, measured: overall loudness and peaks, then each clip against everything
/// else playing at that moment — the sound equivalent of rendering frames to look at them.
public struct MixReport: Sendable {
    public struct Row: Sendable {
        public var id: String
        public var src: String
        public var from: Double
        public var to: Double
        /// Scene time of the clip's loudest 0.4 s.
        public var peakAt: Double
        /// Loudness (LUFS) of the clip in that window, and of everything else playing in the same window.
        public var level: Double
        public var rest: Double
        /// Loudness of the reference audio in that window (nil when it is silent there or this is it).
        public var reference: Double?
        public var isReference: Bool
        public var marker: String?
    }

    public var duration: Double
    public var lufs: Double
    public var truePeakDB: Double
    public var truePeakAt: Double
    /// Integrated loudness of the reference audio.
    public var referenceLufs: Double?
    public var rows: [Row]
    public var warnings: [String]

    public static func make(_ scene: Scene, rendered r: SceneMix.Rendered, from: Double? = nil, to: Double? = nil) -> MixReport {
        let kMix = Loudness.kWeighted(r.mix)
        let tp = Loudness.truePeak(r.mix)
        var warnings: [String] = r.missing.map { "'\($0)' not found in assets/ — it is silent" }
        var refK: Stereo?  // the reference audio on the scene's timeline, K-weighted
        var refLufs: Double?
        if let ref = r.stems.first(where: \.isReference) {
            var placed = Stereo(count: r.mix.count)
            placed.l.replaceSubrange(ref.range, with: ref.audio.l)
            placed.r.replaceSubrange(ref.range, with: ref.audio.r)
            let k = Loudness.kWeighted(placed)
            refK = k
            refLufs = Loudness.integrated(k)
        }
        let win = Int(0.4 * Stereo.rate)
        var rows: [Row] = []
        for stem in r.stems {
            let from0 = Double(stem.start) / Stereo.rate, to0 = Double(stem.range.upperBound) / Stereo.rate
            if let from, to0 < from { continue }
            if let to, from0 > to { continue }
            let k = Loudness.kWeighted(stem.audio)
            // Loudest 0.4 s of the clip (all of it when shorter).
            var best = 0, bestLevel = -200.0
            if k.count <= win {
                bestLevel = Loudness.level(k)
            } else {
                var i = 0
                while i + win <= k.count {
                    let v = Loudness.level(k, i..<(i + win))
                    if v > bestLevel { bestLevel = v; best = i }
                    i += win / 8
                }
            }
            let n = min(win, k.count)
            let scene0 = stem.start + best
            // Everything else in that window: the mix minus this clip (K-weighting is linear).
            var rest = Stereo(count: n)
            for i in 0..<n {
                rest.l[i] = kMix.l[scene0 + i] - k.l[best + i]
                rest.r[i] = kMix.r[scene0 + i] - k.r[best + i]
            }
            let refHere = stem.isReference ? nil : refK.map { Loudness.level($0, scene0..<(scene0 + n)) }
            let peakAt = Double(scene0) / Stereo.rate + Double(n) / Stereo.rate / 2
            // Where the sound starts being heard, against the nearest marker.
            let stemPeak = stem.audio.peak
            let heard =
                (0..<stem.audio.count).first { max(abs(stem.audio.l[$0]), abs(stem.audio.r[$0])) >= stemPeak * 0.05 }
                .map { Double(stem.start + $0) / Stereo.rate } ?? from0
            let near = (scene.markers ?? []).min { abs($0.t - heard) < abs($1.t - heard) }
            let marker = near.flatMap { m -> String? in
                let d = heard - m.t
                return abs(d) <= 0.5 ? "\(m.name) \(d >= 0 ? "+" : "−")\(Format.number((abs(d) * 100).rounded() / 100))s" : nil
            }
            func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
            let row = Row(
                id: stem.id, src: stem.ref.src, from: AudioAnalysis.round2(from0), to: AudioAnalysis.round2(to0),
                peakAt: AudioAnalysis.round2(peakAt), level: r1(bestLevel), rest: r1(Loudness.level(rest)),
                // The scene audio counts as playing there when it is within 20 dB of its usual level.
                reference: refHere.flatMap { v in refLufs.map { v > $0 - 20 } == true ? r1(v) : nil }, isReference: stem.isReference, marker: marker)
            rows.append(row)

            let name = stem.isReference ? "the scene audio" : "'\(stem.id)'"
            if !stem.isReference {
                if bestLevel < -70 {
                    warnings.append("\(name) is practically silent (\(Format.number(row.level)) LUFS) — raise its level or remove it")
                } else if row.rest > -70, bestLevel < row.rest - 24 {
                    warnings.append(
                        "\(name) at \(Format.number(row.peakAt))s is buried: \(Format.number(r1(row.rest - bestLevel))) dB under what plays with it")
                }
                // Against the voice at that moment, or (between words) a little under its usual level.
                if let v = row.reference, let rl = refLufs, bestLevel > max(v, rl - 6) - 3 {
                    warnings.append(
                        "\(name) at \(Format.number(row.peakAt))s competes with the scene audio: clip \(Format.number(row.level)) LUFS, scene audio \(Format.number(v)) there — effects usually sit 6–12 dB under a voice")
                } else if row.reference == nil, let rl = refLufs, bestLevel > rl + 6 {
                    warnings.append(
                        "\(name) at \(Format.number(row.peakAt))s is \(Format.number(r1(bestLevel - rl))) dB louder than the scene audio's usual level — it will jump out")
                }
            }
            // Cuts with signal still present and no fade click.
            func loud(_ x: ArraySlice<Float>) -> Bool { (x.map { abs($0) }.max() ?? 0) > 0.02 }
            if stem.clip.fadeIn <= 0, from0 > 0.001, loud(stem.audio.l.prefix(8)) || loud(stem.audio.r.prefix(8)) {
                warnings.append("\(name) starts mid-sound at \(Format.number(row.from))s with no fade (click) — add fadeIn 0.01–0.05")
            }
            if stem.clip.fadeOut <= 0, loud(stem.audio.l.suffix(8)) || loud(stem.audio.r.suffix(8)) {
                warnings.append("\(name) is cut mid-sound at \(Format.number(row.to))s with no fade (click) — add fadeOut 0.02 or more")
            }
        }
        let lufs = Loudness.integrated(kMix)
        if tp.db > -1 {
            warnings.insert(
                "the mix peaks at \(Format.number((tp.db * 10).rounded() / 10)) dBTP at \(Format.number(AudioAnalysis.round2(tp.at)))s (over −1): it will distort — lower the clips sounding there",
                at: 0)
        }
        return MixReport(
            duration: scene.duration, lufs: (lufs * 10).rounded() / 10, truePeakDB: (tp.db * 10).rounded() / 10,
            truePeakAt: AudioAnalysis.round2(tp.at), referenceLufs: refLufs.map { ($0 * 10).rounded() / 10 }, rows: rows,
            warnings: warnings)
    }

    public var text: String {
        var lines = [
            "mix: \(Format.number(lufs)) LUFS integrated, true peak \(Format.number(truePeakDB)) dBTP at \(Format.number(truePeakAt))s"
                + (referenceLufs.map { "; scene audio \(Format.number($0)) LUFS" } ?? "; no scene audio")
        ]
        lines.append("clips (level = loudest 0.4s of the clip in LUFS; rest = everything else playing then; Δ = level − rest):")
        for r in rows {
            var l =
                "  \(r.id)  \(Format.number(r.from))–\(Format.number(r.to))s  loudest at \(Format.number(r.peakAt))s  level \(Format.number(r.level))"
            if r.rest > -100 {
                l += "  rest \(Format.number(r.rest))  Δ \(Format.number(((r.level - r.rest) * 10).rounded() / 10))"
            } else {
                l += "  alone"
            }
            if let v = r.reference { l += "  vs scene audio \(Format.number(((r.level - v) * 10).rounded() / 10))" }
            if let m = r.marker { l += "  starts at \(m)" }
            lines.append(l)
        }
        if rows.isEmpty { lines.append("  (no sound in this range)") }
        lines.append(warnings.isEmpty ? "no problems measured" : "problems:\n" + warnings.map { "  ! " + $0 }.joined(separator: "\n"))
        return lines.joined(separator: "\n")
    }
}
