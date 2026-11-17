import AppKit
import ArclightCore
import SwiftUI

/// ⌥ + scroll (mouse or trackpad) and pinch zoom the timeline at the pointer; sideways scroll / ⇧ + scroll pans,
/// except over the audio or sounds lane, where ⇧ + scroll makes that lane taller or shorter.
/// Plain vertical scrolling is left to the layer list. Also tracks whether the last click was in the timeline's
/// track area (ruler, audio lane, tracks), which decides whether ⌫ / ⌥← → act on selected keyframes.
final class TimelineScrollMonitor: ObservableObject {
    weak var doc: EditorDocument?
    var region: CGRect = .zero
    var trackX: CGFloat = 0
    var trackW: CGFloat = 1
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
        if e.modifierFlags.contains(.shift), let key = lane(at: p.y - region.minY, doc: doc) {
            // A mouse wheel with ⇧ arrives as sideways scroll (AppKit swaps the axes); a trackpad keeps dy.
            let d = precise ? dy : (dy != 0 ? dy : dx)
            if !precise || abs(dy) >= abs(dx) {
                TL.resizeLane(key, by: precise ? d * 0.5 : d * 4)
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

    /// The resizable lane (its height pref key) at `y` points below the top of the timeline area, if any.
    private func lane(at y: CGFloat, doc: EditorDocument) -> String? {
        var top = TL.rulerH + 1
        if doc.scene.audio != nil {
            if y >= top && y < top + TL.audioH { return Pref.audioLaneHeight }
            top += TL.audioH + 1
        }
        if doc.scene.sounds?.isEmpty == false, y >= top && y < top + TL.soundsH { return Pref.soundsLaneHeight }
        return nil
    }
}
