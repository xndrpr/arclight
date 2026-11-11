import Foundation

/// ISO 8601 timestamps with fractional seconds, as stored in activity logs, notes and presence files.
public enum Timestamp {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// "2026-11-11T09:30:00.123Z"
    public static func string(_ date: Date = Date()) -> String { iso.string(from: date) }

    /// Parses with or without fractional seconds.
    public static func parse(_ s: String) -> Date? { iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) }
}
