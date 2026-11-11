import SwiftUI

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(UI.border).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: AnyView? = nil
    var body: some View {
        HStack(spacing: 6) {
            SmallCapsLabel(title)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, 12).frame(height: 30)
    }
}

/// Borderless icon button with a hover background.
struct IconButton: View {
    let symbol: String
    var help: String = ""
    var active = false
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: {
            ClickTrace.fired("icon button \(symbol)"); action()
        }) {
            Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                .foregroundStyle(active ? UI.accent : (hover ? UI.text : UI.dim))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover || active ? UI.hover : .clear))
                .barHit()
        }
        .buttonStyle(TracedPlainButtonStyle(name: "icon \(symbol)")).help(help).onHover { hover = $0 }.cursor(
            .pointingHand)
    }
}

/// Plain bordered text field used throughout the inspector.
struct FieldBox<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        content
            .textFieldStyle(.plain).font(UI.mono).foregroundStyle(UI.text)
            .padding(.horizontal, 8).frame(minHeight: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(UI.field))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.fieldBorder, lineWidth: 1))
    }
}

/// Primary (white) and secondary (outlined) buttons.
struct PillButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(primary ? UI.onAccent : UI.text)
            .padding(.horizontal, 12).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(primary ? UI.accent : UI.raised))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(primary ? .clear : UI.border, lineWidth: 1))
            .barHit()
            .opacity(configuration.isPressed ? 0.75 : 1)
            .onChange(of: configuration.isPressed) { _, on in ClickTrace.pressed("pill button", on) }
            .cursor(.pointingHand)
    }
}
