import AppKit
import ArclightCore
import SwiftUI

extension JSONValue {
    /// Compact single-line JSON for display/editing.
    var compactString: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: enc.encode(self), encoding: .utf8)) ?? ""
    }

    static func parse(_ s: String) -> JSONValue? {
        try? JSONDecoder().decode(JSONValue.self, from: Data(s.utf8))
    }
}

extension Color {
    init?(arclight v: JSONValue?) {
        guard let c = RGBA.parse(v) else { return nil }
        self = Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }

    /// `#RRGGBB` or `#RRGGBBAA` (sRGB).
    var hex: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .white
        func h(_ x: CGFloat) -> String { String(format: "%02X", Int((x * 255).rounded())) }
        let a = ns.alphaComponent
        return "#" + h(ns.redComponent) + h(ns.greenComponent) + h(ns.blueComponent) + (a < 0.999 ? h(a) : "")
    }
}

/// Takes keyboard focus away from any text field, so transport keys and ⌘Z go to the editor.
func endEditing() {
    if let w = NSApp.keyWindow, w.firstResponder is NSText { w.makeFirstResponder(nil) }
}

/// `x` rounded to `places` decimals, e.g. `rounded(1.234, places: 2)` is 1.23.
func rounded(_ x: Double, places: Int) -> Double {
    let m = pow(10, Double(places))
    return (x * m).rounded() / m
}

extension URL {
    /// The path with the home folder shown as `~`.
    var tildePath: String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
}

func fmt(_ d: Double) -> String {
    if d.rounded() == d && abs(d) < 1e9 { return String(Int(d)) }
    // Trailing zeros of the fraction go, and the dot with them when nothing is left ("2.000" → "2", not "2.").
    let s = String(format: "%.3f", d).replacingOccurrences(of: "\\.?0+$", with: "", options: .regularExpression)
    return s == "-0" ? "0" : s
}

func symbol(for type: String) -> String {
    switch type {
    case "text": return "textformat"
    case "shape": return "square.on.circle"
    case "image": return "photo"
    case "group": return "folder"
    case "repeater": return "circle.grid.3x3"
    case "light": return "lightbulb"
    default: return "circle"
    }
}
