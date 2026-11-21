import AppKit
import ArclightCore
import SwiftUI

/// ⌥ + scroll (mouse or trackpad) and pinch zoom the timeline at the pointer; sideways scroll pans, and so does
/// ⇧ + scroll over the ruler. ⇧ + scroll over the rows makes them taller or shorter, over the audio or sounds
/// lane that lane.
/// Plain vertical scrolling is left to the layer list. Also tracks whether the last click was in the timeline's
/// track area (ruler, audio lane, tracks), which decides whether ⌫ / ⌥← → act on selected keyframes.
final class TimelineScrollMonitor {
    weak var doc: EditorDocument?
    var region: CGRect = .zero
    var trackX: CGFloat = 0
    var trackW: CGFloat = 1
    /// Window frames of the audio / sounds lanes, by height pref key (they scroll with the rows).
    var lanes: [String: CGRect] = [:]
    private lazy var monitor = LocalEventMonitor([.scrollWheel, .magnify, .leftMouseDown, .rightMouseDown]) {
        [weak self] e in
        guard let self else { return e }
        return self.handle(e)  // nil = consumed; `?? e` would pass consumed events on anyway
    }

    func attach(_ d: EditorDocument) {
        doc = d
        monitor.install()
    }

    func detach() { monitor.remove() }

    private func handle(_ e: NSEvent) -> NSEvent? {
        guard let doc, let w = e.window, (w.windowController as? EditorWindowController)?.doc === doc,
            let h = w.contentView?.bounds.height
        else { return e }
        if FloatingRegions.contains(e) {
            if e.type == .leftMouseDown || e.type == .rightMouseDown { doc.timelineUI.focused = false }
            return e
        }
        let p = CGPoint(x: e.locationInWindow.x, y: h - e.locationInWindow.y)
        if e.type == .leftMouseDown || e.type == .rightMouseDown {
            doc.timelineUI.focused = region.contains(p) && p.x >= trackX
            return e
        }
        guard region.contains(p) else { return e }
        let map = TimeMap(doc: doc, width: trackW)
        let anchor = map.t(p.x - trackX)
        if e.type == .magnify {
            doc.zoomTimeline(by: 1 + e.magnification, anchor: anchor)
            return nil
        }
        let precise = e.hasPreciseScrollingDeltas
        if e.modifierFlags.contains(.option) {
            let dy = e.scrollingDeltaY != 0 ? e.scrollingDeltaY : e.scrollingDeltaX
            doc.zoomTimeline(by: exp(Double(dy) * (precise ? 0.01 : 0.08)), anchor: anchor)
            return nil
        }
        let dx = e.scrollingDeltaX, dy = e.scrollingDeltaY
        if e.modifierFlags.contains(.shift), let key = resizable(at: p) {
            // A mouse wheel with ⇧ arrives as sideways scroll (AppKit swaps the axes); a trackpad keeps dy.
            let d = precise ? dy : (dy != 0 ? dy : dx)
            if !precise || abs(dy) >= abs(dx) {
                TL.resize(key, by: precise ? d * 0.5 : d * 4)
                return nil
            }
        }
        if abs(dx) > abs(dy) || e.modifierFlags.contains(.shift) {
            let d = abs(dx) > abs(dy) ? dx : dy
            // past the end extends the timeline
            doc.setTimelineOffset(doc.tlOffset - Double((precise ? d : d * 8) / map.pps))
            return nil
        }
        return e
    }

    /// What ⇧ + scroll resizes at `p` (its height pref key): a lane, else the layer rows; nil over the ruler.
    private func resizable(at p: CGPoint) -> String? {
        guard p.y > region.minY + TL.rulerH + 1 else { return nil }
        return lanes.first { $0.value.contains(p) }?.key ?? Pref.layerRowHeight
    }
}
