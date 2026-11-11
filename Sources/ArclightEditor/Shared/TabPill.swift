import SwiftUI

extension View {
    /// The label of one tab in a strip (sidebar, Settings, activity filters). The selected tab's pill slides between
    /// tabs (`id` in `namespace`). The clickable area reaches the neighbouring tabs (`gap` on each side) and is
    /// `hitHeight` tall, or the strip's full height when nil: a quick tap on the move lands a few points off the pill
    /// and must still count.
    func tabPill(
        selected: Bool, padding: CGFloat, height: CGFloat, cornerRadius: CGFloat, gap: CGFloat, hitHeight: CGFloat?,
        id: String, in namespace: Namespace.ID
    ) -> some View {
        modifier(
            TabPill(
                selected: selected, padding: padding, height: height, cornerRadius: cornerRadius, gap: gap,
                hitHeight: hitHeight, id: id, namespace: namespace))
    }
}

private struct TabPill: ViewModifier {
    let selected: Bool
    let padding, height, cornerRadius, gap: CGFloat
    let hitHeight: CGFloat?
    let id: String
    let namespace: Namespace.ID

    @ViewBuilder
    func body(content: Content) -> some View {
        let pill =
            content
            .foregroundStyle(selected ? UI.text : UI.dim)
            .padding(.horizontal, padding).frame(height: height)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: cornerRadius).fill(UI.selected).matchedGeometryEffect(
                        id: id, in: namespace)
                }
            }
            .padding(.horizontal, gap)
        if let hitHeight {
            pill.frame(height: hitHeight).hitArea()
        } else {
            pill.frame(maxHeight: .infinity).hitArea()
        }
    }
}
