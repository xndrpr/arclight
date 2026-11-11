import Foundation

public enum Format {
    /// "3" for whole numbers, otherwise `%g` ("0.25", "1.5e-05").
    public static func number(_ d: Double) -> String { d.rounded() == d ? String(Int(d)) : String(format: "%g", d) }
}
