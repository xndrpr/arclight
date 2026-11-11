import AppKit
import ArclightCore
import SwiftUI

/// Arclight's scene model (not SwiftUI.Scene).
typealias Scene = ArclightCore.Scene

/// Editor colours come from the active app theme (Settings ▸ Editor ▸ Theme). Views read `UI.*` and the
/// window root re-renders on a theme change (`.themedRoot()`), so these stay plain static accessors.
/// Never hard-code `Color.white` / `Color.black` / `Color(white:)` for chrome: use these tokens.
enum UI {
    static var p: Palette { AppTheme.current.palette }
    static var bg: Color { p.bg }
    static var panel: Color { p.panel }
    static var raised: Color { p.raised }
    static var field: Color { p.field }
    static var border: Color { p.border }
    static var fieldBorder: Color { p.fieldBorder }
    static var hover: Color { p.hover }
    static var selected: Color { p.selected }
    static var text: Color { p.text }
    /// Property labels and secondary text that must stay readable.
    static var label2: Color { p.label2 }
    static var dim: Color { p.dim }
    static var faint: Color { p.faint }
    /// Primary buttons, active toggles, playhead, selection outlines.
    static var accent: Color { p.accent }
    /// Text/icons drawn on top of `accent` (primary button label).
    static var onAccent: Color { p.onAccent }
    /// Semantic colours (problems, AI activity, recording).
    static var danger: Color { p.danger }
    static var warning: Color { p.warning }
    static var success: Color { p.success }
    static var ai: Color { p.ai }
    static var isDark: Bool { p.isDark }
    static var scheme: ColorScheme { p.isDark ? .dark : .light }

    static let font = Font.system(size: 12.5)
    static let small = Font.system(size: 11.5)
    static let label = Font.system(size: 10.5, weight: .semibold)
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 10.5, design: .monospaced)

    /// Standard UI motion: quick, no bounce.
    static let snappy = Animation.spring(response: 0.28, dampingFraction: 0.9)
    static let fade = Animation.easeOut(duration: 0.16)
}

struct Palette {
    var isDark: Bool
    var bg, panel, raised, field, border, fieldBorder, hover, selected: Color
    var text, label2, dim, faint, accent, onAccent: Color
    var danger = Color(hex: 0xEF4444), warning = Color(hex: 0xEAB308), success = Color(hex: 0x22C55E),
        ai = Color(hex: 0xA78BFA)
}
extension Color {
    init(hex: UInt32) {
        self = Color(
            .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}
