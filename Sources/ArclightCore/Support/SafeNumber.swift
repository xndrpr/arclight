import Foundation

/// Turns numbers from JSON or the command line into checked values. `Int(Double)` traps on non-finite or huge values,
/// so every outside number that becomes an `Int` (or feeds one later, like a canvas size or frame rate) goes through
/// here and fails with a clear error instead of crashing the process.
public enum SafeNumber {
    /// Largest canvas side in pixels (Metal's texture limit).
    public static let maxCanvas = 16384
    /// Highest frame rate accepted for projects, scenes and exports.
    public static let maxFPS = 1000.0
    /// Longest scene, in seconds (24 hours).
    public static let maxDuration = 86400.0
    /// Largest export or render scale.
    public static let maxScale = 16.0
    /// Largest revision number or list limit accepted from outside.
    public static let maxCount = Int(Int32.max)

    /// An integer in `range`; a fraction is truncated toward zero, as `Int(_:)` does. Throws for a non-finite value or
    /// one outside the range. `what` names the value in the message.
    public static func int(_ d: Double, _ what: String, in range: ClosedRange<Int>) throws -> Int {
        guard d.isFinite, d >= Double(range.lowerBound), d < Double(range.upperBound) + 1 else {
            throw ModelError.invalid("\(what) must be a number from \(range.lowerBound) to \(range.upperBound)")
        }
        return Int(d)
    }

    /// An integer clamped into `range`, for positions such as a layer index where "past the end" means the end.
    /// Throws only for a non-finite value.
    public static func clampedInt(_ d: Double, _ what: String, to range: ClosedRange<Int>) throws -> Int {
        guard d.isFinite else { throw ModelError.invalid("\(what) must be a finite number") }
        if d <= Double(range.lowerBound) { return range.lowerBound }
        if d >= Double(range.upperBound) { return range.upperBound }
        return Int(d)
    }

    /// A finite number above 0 and at most `max` (a frame rate, a duration, a scale).
    public static func positive(_ d: Double, _ what: String, max: Double) throws -> Double {
        guard d.isFinite, d > 0, d <= max else {
            throw ModelError.invalid("\(what) must be a number above 0 and at most \(describe(max))")
        }
        return d
    }

    /// A number as text: an integer when it is one, else `%g`. Never traps (for log lines and messages).
    public static func describe(_ d: Double) -> String {
        Int(exactly: d).map(String.init) ?? String(format: "%g", d)
    }
}
