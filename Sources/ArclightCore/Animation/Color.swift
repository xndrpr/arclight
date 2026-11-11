import Foundation
import simd

/// sRGB color with straight alpha, components 0...1.
public struct RGBA: Equatable, Sendable {
    public var r, g, b, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    static let named: [String: RGBA] = [
        "white": RGBA(1, 1, 1), "black": RGBA(0, 0, 0), "transparent": RGBA(0, 0, 0, 0),
        "red": RGBA(1, 0.231, 0.188), "green": RGBA(0.204, 0.78, 0.349), "blue": RGBA(0, 0.478, 1),
        "yellow": RGBA(1, 0.8, 0), "gray": RGBA(0.5, 0.5, 0.5),
    ]

    /// Accepts `"#RGB"`, `"#RRGGBB"`, `"#RRGGBBAA"`, a CSS-ish name, or `[r, g, b, a?]` in 0...1.
    public static func parse(_ v: JSONValue?) -> RGBA? {
        switch v {
        case .string(let s)?:
            if let n = named[s.lowercased()] { return n }
            guard s.hasPrefix("#") else { return nil }
            var hex = String(s.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let x = UInt64(hex, radix: 16) else { return nil }
            if hex.count == 6 {
                return RGBA(Double((x >> 16) & 0xFF) / 255, Double((x >> 8) & 0xFF) / 255, Double(x & 0xFF) / 255)
            }
            return RGBA(
                Double((x >> 24) & 0xFF) / 255, Double((x >> 16) & 0xFF) / 255, Double((x >> 8) & 0xFF) / 255,
                Double(x & 0xFF) / 255)
        case .array(let a)?:
            let d = a.compactMap(\.double)
            guard d.count == 3 || d.count == 4 else { return nil }
            return RGBA(d[0], d[1], d[2], d.count == 4 ? d[3] : 1)
        default:
            return nil
        }
    }

    public var json: JSONValue { [.number(r), .number(g), .number(b), .number(a)] }

    /// `"#RRGGBBAA"`, each component clamped to 0…1 and rounded to 8 bits.
    public var hex: String {
        [r, g, b, a].map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }
            .reduce("#", +)
    }

    static func toLinear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }

    /// Linear-light, premultiplied, with extra opacity applied. This is what shaders consume.
    public func linearPremultiplied(opacity: Double = 1) -> SIMD4<Float> {
        let al = a * opacity
        return SIMD4(
            Float(RGBA.toLinear(r) * al), Float(RGBA.toLinear(g) * al), Float(RGBA.toLinear(b) * al), Float(al))
    }
}
