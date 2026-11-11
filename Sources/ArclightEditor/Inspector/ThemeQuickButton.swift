import ArclightCore
import SwiftUI

/// Top-bar button for the project theme: the palette as overlapping dots + a chevron. Click → `ThemePopover`
/// (presets, token editor, save as preset).
struct ThemeQuickButton: View {
    @ObservedObject var doc: EditorDocument
    @State private var open = false
    @State private var hover = false

    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 5) {
                ThemeDots(colors: doc.themeSwatchColors)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(UI.dim)
            }
            .padding(.horizontal, 7).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover || open ? UI.hover : .clear))
            .barHit()
        }
        .buttonStyle(.plain).onHover { hover = $0 }.cursor(.pointingHand)
        .help(
            "Project theme: colours and fonts of every scene" + (doc.currentThemePreset.map { " (\($0.name))" } ?? "")
        )
        .accessibilityLabel("Project theme")
        .popover(isPresented: $open, arrowEdge: .bottom) { ThemePopover(doc: doc) }
    }
}

/// Up to four overlapping colour dots (background first, outlined so a black dot shows on black chrome).
private struct ThemeDots: View {
    let colors: [String]
    var size: CGFloat = 14
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = Array(colors.prefix(4))
        HStack(spacing: -size * 0.38) {
            ForEach(Array(shown.enumerated()), id: \.offset) { i, c in
                Circle().fill(Color(arclight: .string(c)) ?? .clear)
                    .overlay(Circle().stroke(UI.fieldBorder, lineWidth: 1))
                    .background(Circle().fill(UI.panel).padding(-1.5))
                    .frame(width: size, height: size)
                    .zIndex(Double(shown.count - i))
            }
        }
        .animation(reduceMotion ? nil : UI.fade, value: shown)
        .accessibilityHidden(true)
    }
}

/// Scene-inspector row that shows the current theme and opens the theme popover.
struct ThemeRow: View {
    @ObservedObject var doc: EditorDocument
    @State private var open = false

    var body: some View {
        NavRowButton(action: { open = true }) {
            ThemeDots(colors: doc.themeSwatchColors, size: 13)
            Text(doc.currentThemePreset?.name ?? "Custom").font(UI.font).foregroundStyle(UI.text).lineLimit(1)
            Spacer(minLength: 4)
            Text("Change").font(UI.small).foregroundStyle(UI.dim)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(UI.faint)
        }
        .help("Pick a preset or edit the theme colours and fonts — every scene restyles")
        .popover(isPresented: $open, arrowEdge: .leading) { ThemePopover(doc: doc) }
    }
}
