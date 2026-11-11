import AppKit
import SwiftUI

/// Shell animations that respect System Settings ▸ Accessibility ▸ Reduce motion (fades instead of slides).
enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// `a`, or no animation when reduced motion is on.
    static func animation(_ a: Animation) -> Animation? { reduce ? nil : a }

    /// Panels, tab highlights, pills.
    static var snappy: Animation { reduce ? UI.fade : UI.snappy }

    /// Tab content: the new page comes in from the side of the tab that was clicked, the old one leaves the other way.
    static func page(forward: Bool) -> AnyTransition {
        guard !reduce else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity))
    }

    /// New rows in a feed: a short drop-in.
    static var row: AnyTransition {
        reduce ? .opacity : .opacity.combined(with: .offset(y: -6))
    }
}
