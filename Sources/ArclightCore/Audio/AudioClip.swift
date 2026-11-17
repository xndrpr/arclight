import Foundation

/// Where the scene's reference audio sits on the timeline, and its gain envelope — the same placement the
/// exporter uses (`SceneAudio.mux`): file second `trim` plays at scene time `offset` for `length` seconds (default
/// the rest of the file); audio is cut at the scene end; fade-in starts where the audio becomes audible (≥ 0),
/// fade-out ends where it stops (its end or the scene end).
public struct AudioClip: Equatable, Sendable {
    public var offset: Double
    public var trim: Double
    /// Length of the audio file (s).
    public var fileDuration: Double
    public var sceneDuration: Double
    public var gain: Double
    public var fadeIn: Double
    public var fadeOut: Double
    /// Seconds played from `trim` (nil: to the end of the file).
    public var length: Double?

    public init(_ a: AudioRef, fileDuration: Double, sceneDuration: Double) {
        offset = a.offset ?? 0
        trim = max(0, a.trim ?? 0)
        self.fileDuration = fileDuration
        self.sceneDuration = sceneDuration
        gain = a.gain ?? 1
        fadeIn = max(0, a.fadeIn ?? 0)
        fadeOut = max(0, a.fadeOut ?? 0)
        length = a.length.map { max(0, $0) }
    }

    /// Scene time where the clip starts (may be negative: the head is cut off by the scene start).
    public var start: Double { offset }
    /// Scene time where the fade-out starts.
    public var fadeOutStart: Double { max(audibleStart, audibleEnd - fadeOut) }
    /// Scene time where the file (or `length`) runs out.
    public var end: Double { offset + max(0, min(fileDuration - trim, length ?? .infinity)) }
    /// Scene time where audio stops in the export (file end or scene end).
    public var audibleEnd: Double { min(end, sceneDuration) }
    public var audibleStart: Double { max(0, start) }

    /// File position (s) playing at a scene time.
    public func filePosition(at t: Double) -> Double { trim + (t - offset) }

    /// Gain at a scene time (0 outside the audible range), with linear fades like the export's volume ramps.
    public func envelope(at t: Double) -> Double {
        guard t >= audibleStart, t < audibleEnd else { return 0 }
        var g = gain
        if fadeIn > 0 { g *= min(1, (t - audibleStart) / fadeIn) }
        if fadeOut > 0 { g *= min(1, max(0, (audibleEnd - t) / fadeOut)) }
        return g
    }

    /// What to play when playback starts at scene time `t` and runs until `until` (scene end or loop end):
    /// where to start reading the file, how long to wait first, and how much to play. Nil when nothing is audible.
    public struct Segment: Equatable, Sendable { public var fileStart: Double; public var delay: Double; public var duration: Double }

    public func segment(from t: Double, until: Double) -> Segment? {
        let stop = min(audibleEnd, until)
        let from = max(t, audibleStart)
        guard stop - from > 1e-3 else { return nil }
        return Segment(fileStart: filePosition(at: from), delay: from - t, duration: stop - from)
    }

    /// A segment in file frames, clamped to the file: (first frame, frame count). Nil when empty.
    public static func frames(_ seg: Segment, sampleRate: Double, fileFrames: Int64) -> (start: Int64, count: Int64)? {
        let start = max(0, min(fileFrames, Int64((seg.fileStart * sampleRate).rounded())))
        let count = min(fileFrames - start, Int64((seg.duration * sampleRate).rounded()))
        return count > 0 ? (start, count) : nil
    }

    // MARK: Edits (return the new AudioRef fields)

    /// Moves the whole clip so it starts at `newStart`.
    public func moved(to newStart: Double) -> (offset: Double, trim: Double) { (newStart, trim) }

    /// Trims the head: the clip now starts at `newStart` but the content stays where it was in the scene.
    /// Clamped so the trim stays ≥ 0 and at least `minLength` of audio remains.
    public func trimmedStart(to newStart: Double, minLength: Double = 0.05) -> (offset: Double, trim: Double) {
        let s = min(max(newStart, offset - trim), end - minLength)
        return (s, trim + (s - offset))
    }

    /// Gain from a vertical position in the lane (0 = bottom … 1 = top); gain 1 sits at the middle, max 2 (+6 dB).
    public static func gain(fromUnitY y: Double) -> Double { min(2, max(0, y * 2)) }
    public static func unitY(gain: Double) -> Double { min(1, max(0, gain / 2)) }

    public static func dB(_ g: Double) -> String {
        guard g > 0.0001 else { return "−∞ dB" }
        let d = 20 * log10(g)
        return String(format: "%@%.1f dB", d >= 0 ? "+" : "−", abs(d))
    }
}
