import SwiftUI

// Shared building blocks for editor controls. Every plain-button label here ends in `.hitArea()`, so the whole frame
// takes clicks, not only the drawn text.

extension View {
    /// The inspector's field look: inset content, row height, field fill and border, whole frame clickable.
    func fieldChrome(height: CGFloat = UI.rowHeight, border: Color = UI.fieldBorder) -> some View {
        padding(.horizontal, 8).frame(height: height)
            .background(RoundedRectangle(cornerRadius: 6).fill(UI.field))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(border, lineWidth: 1))
            .hitArea()
    }

    /// Padding, optional fixed width and panel background for popover content.
    func popoverChrome(width: CGFloat? = nil) -> some View {
        padding(14).frame(width: width).background(UI.panel)
    }
}

/// A field-looking button that opens a picker: `label`, then the up/down chevron.
struct FieldButton<Label: View>: View {
    /// Spacing between label and chevron; nil is the system default.
    var spacing: CGFloat? = nil
    var height: CGFloat = UI.rowHeight
    var border: Color = UI.fieldBorder
    let action: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: action) {
            HStack(spacing: spacing) {
                label
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(UI.dim)
            }
            .fieldChrome(height: height, border: border)
        }
        .buttonStyle(.plain).cursor(.pointingHand)
    }
}

/// Small outlined button: secondary text on `UI.raised`, brighter on hover. Logs presses to ClickTrace.
struct HoverButtonStyle: ButtonStyle {
    /// Name in the click diagnostics log.
    var name = "button"
    var height: CGFloat = 22
    var cornerRadius: CGFloat = 5

    func makeBody(configuration: Configuration) -> some View {
        HoverButtonBody(configuration: configuration, style: self)
    }
}

private struct HoverButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: HoverButtonStyle
    @State private var hover = false

    var body: some View {
        configuration.label
            .foregroundStyle(hover ? UI.text : UI.label2)
            .padding(.horizontal, 8).frame(height: style.height)
            .background(RoundedRectangle(cornerRadius: style.cornerRadius).fill(hover ? UI.hover : UI.raised))
            .overlay(RoundedRectangle(cornerRadius: style.cornerRadius).stroke(UI.border, lineWidth: 1))
            .hitArea()
            .onHover { hover = $0 }
            .onChange(of: configuration.isPressed) { _, on in ClickTrace.pressed(style.name, on) }
            .cursor(.pointingHand)
    }
}

/// Uppercase, tracked section label ("THEME TOKENS").
struct SmallCapsLabel: View {
    let text: String
    var color: Color = UI.dim
    init(_ text: String, color: Color = UI.dim) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(UI.label).tracking(0.8).foregroundStyle(color)
    }
}

/// A row that folds something open: a chevron (pointing right, down when open) before `label`; the whole row clicks.
struct DisclosureButton<Label: View>: View {
    let open: Bool
    var chevronSize: CGFloat = 8.5
    var spacing: CGFloat = 5
    let toggle: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: spacing) {
                Image(systemName: "chevron.right").font(.system(size: chevronSize, weight: .bold)).foregroundStyle(
                    UI.faint
                )
                .rotationEffect(.degrees(open ? 90 : 0))
                label
                Spacer(minLength: 0)
            }
            .hitArea()
        }
        .buttonStyle(.plain).cursor(.pointingHand)
    }
}
