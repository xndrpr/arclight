import SwiftUI

/// Which inspector sections are collapsed (by title), shared by every inspector page for the session.
private final class InspectorCollapse: ObservableObject {
    static let shared = InspectorCollapse()
    @Published var closed: Set<String> = []

    func isOpen(_ title: String) -> Bool { !closed.contains(title) }
    func toggle(_ title: String) {
        if closed.contains(title) { closed.remove(title) } else { closed.insert(title) }
    }
}

/// Uppercase section header on the inspector grid (`UI.inset`). With `collapsible`, clicking the title
/// folds the section (chevron after the title); `trailing` holds the section's buttons, right-aligned.
struct SectionTitle: View {
    let title: String
    var collapsible = false
    var open = true
    var trailing: AnyView? = nil
    var toggle: () -> Void = {}
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            if collapsible {
                Button(action: toggle) {
                    HStack(spacing: 5) {
                        label
                        Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(hover ? UI.dim : UI.faint)
                            .rotationEffect(.degrees(open ? 0 : -90))
                        Spacer(minLength: 0)
                    }
                    .frame(maxHeight: .infinity).hitArea()
                }
                .buttonStyle(.plain).onHover { hover = $0 }.cursor(.pointingHand)
                .help(open ? "Collapse \(title.lowercased())" : "Expand \(title.lowercased())")
            } else {
                label
                Spacer(minLength: 0)
            }
            if let trailing { trailing }
        }
        .padding(.leading, UI.inset).padding(.trailing, UI.inset)
        .frame(height: UI.headerHeight)
    }

    private var label: some View {
        SmallCapsLabel(title).lineLimit(1)
    }
}

/// A collapsible inspector section: header + content (inset on the grid) + hairline. Folding animates
/// unless reduced motion is on.
struct CollapsibleSection<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    /// Searching forces sections open.
    var forceOpen = false
    @ViewBuilder let content: Content
    @ObservedObject private var collapse = InspectorCollapse.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let open = forceOpen || collapse.isOpen(title)
        VStack(alignment: .leading, spacing: 0) {
            SectionTitle(title: title, collapsible: !forceOpen, open: open, trailing: trailing) {
                withAnimation(reduceMotion ? nil : UI.snappy) { collapse.toggle(title) }
            }
            if open {
                content
                    .padding(.horizontal, UI.inset).padding(.bottom, 12)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
            Hairline()
        }
        .clipped()
    }
}
