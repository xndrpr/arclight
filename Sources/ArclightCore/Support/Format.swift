import Foundation

public enum Format {
    /// "3" for whole numbers, otherwise `%g` ("0.25", "1.5e-05").
    public static func number(_ d: Double) -> String { d.rounded() == d ? String(Int(d)) : String(format: "%g", d) }

    /// "812 KB", "1.6 MB" (1024-based, as YouTube's 2 MB limit is).
    public static func bytes(_ n: Int) -> String {
        n < 1024 * 1024 ? "\(max(1, (n + 512) / 1024)) KB" : String(format: "%.1f MB", Double(n) / 1024 / 1024)
    }
}
