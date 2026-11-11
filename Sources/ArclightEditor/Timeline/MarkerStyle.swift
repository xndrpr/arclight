import AppKit
import ArclightCore
import SwiftUI

/// Marker colours and label fitting, shared by the ruler and the marker lines over the tracks.
enum MarkerStyle {
    static let font = Font.system(size: 9, weight: .semibold)
    /// Uncoloured markers: the theme's secondary text colour (readable on light and dark rulers).
    private static var fallback: Color { UI.label2 }

    static func color(_ m: Marker) -> Color { Color(arclight: m.color.map { .string($0) }) ?? fallback }

    /// Black or white label text, whichever reads better on the marker's flag.
    static func textColor(_ m: Marker) -> Color {
        guard let c = NSColor(color(m)).usingColorSpace(.sRGB) else { return .black }
        let l = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return l > 0.5 ? .black : .white
    }

    /// The name shortened with "…" to fit `room` points, or nil when even a few letters don't fit (flag only).
    static func fit(_ name: String, room: CGFloat, measure: (String) -> CGFloat) -> String? {
        guard room >= 14 else { return nil }
        if measure(name) <= room { return name }
        var chars = Array(name)
        while chars.count > 1 {
            chars.removeLast()
            let s = String(chars) + "…"
            if measure(s) <= room { return s }
        }
        return nil
    }
}
