import AppKit
import SwiftUI

extension View {
    /// Shows `cursor` while the pointer is over this view. Uses SwiftUI's pointerStyle on macOS 15+
    /// (stays correct while the mouse moves); falls back to push/pop on macOS 14.
    @ViewBuilder func cursor(_ cursor: NSCursor) -> some View {
        if #available(macOS 15.0, *) {
            self.pointerStyle(PointerStyle.from(cursor))
        } else {
            self.onHover { inside in if inside { cursor.push() } else { NSCursor.pop() } }
        }
    }
}

@available(macOS 15.0, *)
extension PointerStyle {
    static func from(_ c: NSCursor) -> PointerStyle? {
        switch c {
        case NSCursor.pointingHand: return .link
        case NSCursor.iBeam: return .horizontalText
        case NSCursor.resizeLeftRight: return .columnResize
        case NSCursor.resizeUpDown: return .rowResize
        case NSCursor.openHand: return .grabIdle
        case NSCursor.closedHand: return .grabActive
        case NSCursor.crosshair: return .rectSelection
        default: return .default
        }
    }
}
