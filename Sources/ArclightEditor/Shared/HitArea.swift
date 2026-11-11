import SwiftUI

/// Makes the whole frame of a plain button clickable (not just its text/icon). Use on every
/// `.buttonStyle(.plain)` label whose background is clear or only drawn on hover/selection.
extension View {
    func hitArea() -> some View { contentShape(Rectangle()) }
    /// `hitArea()`, and inside a bar that sets `barHitHeight` (the top bar) the clickable area grows to the bar's
    /// full height while the control draws exactly as before. Quick trackpad taps on the move land a few points
    /// above or below a 24 pt pill; in a bar they must still count.
    func barHit() -> some View { modifier(BarHit()) }
}

private struct BarHitHeightKey: EnvironmentKey { static let defaultValue: CGFloat? = nil }
extension EnvironmentValues {
    var barHitHeight: CGFloat? {
        get { self[BarHitHeightKey.self] }
        set { self[BarHitHeightKey.self] = newValue }
    }
}

private struct BarHit: ViewModifier {
    @Environment(\.barHitHeight) private var height
    func body(content: Content) -> some View { content.frame(height: height).contentShape(Rectangle()) }
}
