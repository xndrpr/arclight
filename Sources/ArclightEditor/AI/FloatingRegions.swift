import AppKit

/// Window-space frames (top-left origin) of floating panels, so AppKit event monitors that act on whatever is
/// under the pointer (canvas zoom/pan, timeline scroll, click-to-focus) can leave events over a panel alone.
/// Also tracks whether the last click in a window landed in its panel (Esc then closes the panel).
enum FloatingRegions {
    private static var rects: [ObjectIdentifier: CGRect] = [:]
    private static var focused: Set<ObjectIdentifier> = []
    /// Installed once and never removed: it lives as long as the app.
    private static let focusMonitor = LocalEventMonitor([.leftMouseDown, .rightMouseDown]) { e in
        if let w = e.window {
            if contains(e) { focused.insert(ObjectIdentifier(w)) } else { focused.remove(ObjectIdentifier(w)) }
        }
        return e
    }

    static func set(_ r: CGRect?, for w: NSWindow) {
        let k = ObjectIdentifier(w)
        if let r { rects[k] = r } else { rects[k] = nil; focused.remove(k) }
    }

    /// The panel's frame in `w` (top-left origin), if one is showing.
    static func rect(for w: NSWindow) -> CGRect? { rects[ObjectIdentifier(w)] }

    /// Whether a point in window coordinates (AppKit, as in `NSEvent.locationInWindow`) is over a panel.
    static func contains(windowPoint p: NSPoint, in w: NSWindow) -> Bool {
        guard let r = rects[ObjectIdentifier(w)], let v = w.contentView else { return false }
        let q = v.convert(p, from: nil)
        return r.contains(CGPoint(x: q.x, y: v.isFlipped ? q.y : v.bounds.height - q.y))
    }

    /// Whether a mouse/scroll event is over a floating panel.
    static func contains(_ e: NSEvent) -> Bool {
        guard let w = e.window else { return false }
        return contains(windowPoint: e.locationInWindow, in: w)
    }

    /// The last click in `w` was inside its floating panel.
    static func isFocused(_ w: NSWindow?) -> Bool { w.map { focused.contains(ObjectIdentifier($0)) } ?? false }

    static func installFocusTracking() { focusMonitor.install() }
}
