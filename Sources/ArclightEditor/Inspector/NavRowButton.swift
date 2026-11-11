import SwiftUI

/// A full-width field-coloured row that opens something; the fill lightens on hover.
struct NavRowButton<Label: View>: View {
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) { label }
                .padding(.horizontal, 10).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? UI.hover : UI.field))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.fieldBorder))
                .hitArea()
        }
        .buttonStyle(.plain).onHover { hover = $0 }.cursor(.pointingHand)
    }
}
