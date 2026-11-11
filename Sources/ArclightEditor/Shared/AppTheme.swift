import AppKit
import ArclightCore
import SwiftUI

/// App (chrome) themes. Independent of the project's theme tokens, which style the video itself.
enum AppTheme: String, CaseIterable, Identifiable {
    case dark, light, vitesseDark, vitesseLight, gruvboxDark, gruvboxLight, nord, tokyoNight, catppuccin
    var id: String { rawValue }

    var title: String {
        switch self {
        case .dark: return "Dark"
        case .light: return "Light"
        case .vitesseDark: return "Vitesse Dark"
        case .vitesseLight: return "Vitesse Light"
        case .gruvboxDark: return "Gruvbox Dark"
        case .gruvboxLight: return "Gruvbox Light"
        case .nord: return "Nord"
        case .tokyoNight: return "Tokyo Night"
        case .catppuccin: return "Catppuccin Mocha"
        }
    }

    private static var cached: AppTheme?
    /// The theme last pushed to AppKit (NSApp + windows) by `apply`.
    private static var applied: AppTheme?

    static var current: AppTheme {
        if let c = cached { return c }
        let t = stored
        cached = t
        return t
    }

    /// The saved setting (Settings ▸ Editor ▸ Theme, View ▸ App Theme).
    static var stored: AppTheme { AppTheme(rawValue: Pref.store.string(forKey: Pref.theme) ?? "") ?? .dark }

    var appearance: NSAppearance? { NSAppearance(named: palette.isDark ? .darkAqua : .aqua) }

    /// The one way to change the app theme, from anywhere: saves the setting (every `.themedRoot()` re-renders
    /// through its `@AppStorage`), makes `UI.*` read the new palette, sets the light/dark appearance of NSApp and
    /// of every open window (sheets, popovers, the colour panel…) so system controls follow, repaints themed
    /// window backgrounds, and posts `.appThemeChanged` for long-lived AppKit / Metal objects.
    static func apply(_ t: AppTheme) {
        let d = Pref.store
        if d.string(forKey: Pref.theme) != t.rawValue { d.set(t.rawValue, forKey: Pref.theme) }
        cached = t
        guard applied != t else { return }
        applied = t
        NSApp?.appearance = t.appearance
        for w in NSApp?.windows ?? [] { style(w) }
        NotificationCenter.default.post(name: .appThemeChanged, object: nil)
    }

    /// Picks up a theme saved by someone else (`defaults write`, another process). Cheap; call on any
    /// defaults change.
    static func syncFromDefaults() {
        let t = stored
        if t != applied || t != cached { apply(t) }
    }

    /// Current appearance and (for Arclight content) background on one window; new windows call it once.
    static func style(_ w: NSWindow) {
        let t = current
        w.appearance = t.appearance
        if let c = w.contentView as? ThemedWindowContent {
            w.backgroundColor = NSColor(c.windowBackground.color(t.palette))
        }
    }

    /// Called by `.themedRoot()` while rendering: `UI.*` must read `t` during this very pass, so the cache is
    /// updated at once; the AppKit side follows right after the render (no window mutations inside a view update).
    static func activate(_ t: AppTheme) {
        if cached != t { cached = t }
        guard applied != t else { return }
        DispatchQueue.main.async { if applied != t, stored == t { apply(t) } }
    }

    /// Testing: forget what was pushed to AppKit so the next `apply` runs fully.
    static func resetForTesting() { cached = nil; applied = nil }

    var palette: Palette {
        func P(_ dark: Bool, _ c: [UInt32]) -> Palette {
            let k = c.map { Color(hex: $0) }
            return Palette(
                isDark: dark, bg: k[0], panel: k[1], raised: k[2], field: k[3], border: k[4], fieldBorder: k[5],
                hover: k[6], selected: k[7], text: k[8], label2: k[9], dim: k[10], faint: k[11], accent: k[12],
                onAccent: k[13])
        }
        //            bg        panel     raised    field     border    fieldBd   hover     selected  text      label2    dim       faint     accent    onAccent
        switch self {
        case .dark:
            return P(
                true,
                [
                    0x000000, 0x0A0A0A, 0x161616, 0x131313, 0x262626, 0x333333, 0x1F1F1F, 0x2E2E2E, 0xF2F2F2, 0xBDBDBD,
                    0x999999, 0x5C5C5C, 0xFFFFFF, 0x000000,
                ])
        case .light:
            return P(
                false,
                [
                    0xF0F0F0, 0xFAFAFA, 0xFFFFFF, 0xFFFFFF, 0xE3E3E3, 0xD0D0D0, 0xEDEDED, 0xE0E0E0, 0x0A0A0A, 0x3D3D3D,
                    0x666666, 0xA3A3A3, 0x000000, 0xFFFFFF,
                ])
        case .vitesseDark:
            var p = P(
                true,
                [
                    0x121212, 0x181818, 0x222222, 0x1B1B1B, 0x2A2A2A, 0x363636, 0x252525, 0x2F3A33, 0xDBD7CA, 0xBFBAAA,
                    0x959DA5, 0x5E6066, 0x4D9375, 0x121212,
                ])
            p.ai = Color(hex: 0xB8A965); return p
        case .vitesseLight:
            var p = P(
                false,
                [
                    0xF4F4F2, 0xFFFFFF, 0xFFFFFF, 0xF7F7F7, 0xE7E7E7, 0xD8D8D8, 0xF0F0EE, 0xE2EDE6, 0x393A34, 0x4E4F47,
                    0x6F7069, 0xA0ADA0, 0x1C6B48, 0xFFFFFF,
                ])
            p.ai = Color(hex: 0x8C6C3E); return p
        case .gruvboxDark:
            return P(
                true,
                [
                    0x1D2021, 0x282828, 0x32302F, 0x1D2021, 0x3C3836, 0x504945, 0x3C3836, 0x504945, 0xEBDBB2, 0xD5C4A1,
                    0xA89984, 0x7C6F64, 0xFABD2F, 0x282828,
                ])
        case .gruvboxLight:
            return P(
                false,
                [
                    0xF2E5BC, 0xFBF1C7, 0xF9F5D7, 0xF9F5D7, 0xE5D5AD, 0xD5C4A1, 0xEBDBB2, 0xE0CFA5, 0x3C3836, 0x504945,
                    0x7C6F64, 0xA89984, 0xAF3A03, 0xFBF1C7,
                ])
        case .nord:
            return P(
                true,
                [
                    0x242933, 0x2E3440, 0x3B4252, 0x272C36, 0x3B4252, 0x4C566A, 0x3B4252, 0x434C5E, 0xECEFF4, 0xD8DEE9,
                    0xA3ABBA, 0x6B7689, 0x88C0D0, 0x2E3440,
                ])
        case .tokyoNight:
            return P(
                true,
                [
                    0x16161E, 0x1A1B26, 0x24283B, 0x16161E, 0x292E42, 0x3B4261, 0x292E42, 0x33395A, 0xC0CAF5, 0xA9B1D6,
                    0x828BB8, 0x565F89, 0x7AA2F7, 0x16161E,
                ])
        case .catppuccin:
            return P(
                true,
                [
                    0x11111B, 0x181825, 0x1E1E2E, 0x11111B, 0x313244, 0x45475A, 0x313244, 0x45475A, 0xCDD6F4, 0xBAC2DE,
                    0xA6ADC8, 0x6C7086, 0xCBA6F7, 0x11111B,
                ])
        }
    }
}

/// Apply at the root of every window's SwiftUI content: follows the app theme setting live
/// (re-renders the whole tree when it changes), sets the matching light/dark scheme, and makes `Pref.store` the
/// `@AppStorage` store of everything inside.
private struct ThemedRoot: ViewModifier {
    @AppStorage(Pref.theme, store: Pref.store) private var raw = AppTheme.dark.rawValue
    func body(content: Content) -> some View {
        let t = AppTheme(rawValue: raw) ?? .dark
        AppTheme.activate(t)
        return content.id(t).preferredColorScheme(t.palette.isDark ? .dark : .light).defaultAppStorage(Pref.store)
    }
}

extension View {
    func themedRoot() -> some View { modifier(ThemedRoot()) }
}
