import AppKit
import SwiftUI

/// Zoom and pan of the viewer (view state, not saved in the document). `zoom == nil` means Fit (letterboxed).
final class ViewportState: ObservableObject {
    @Published var zoom: CGFloat?
    /// Offset of the canvas centre from the viewport centre, in points.
    @Published var pan: CGSize = .zero

    /// Last laid-out viewport size, canvas size (px) and Fit padding; set by the viewport.
    var viewSize: CGSize = .zero
    var canvas: CGSize = CGSize(width: 1920, height: 1080)
    var pad: CGFloat = 24
    /// Plain NSView behind the viewport, used to hit-test AppKit events (scroll, pinch, clicks).
    weak var anchorView: NSView?
    let events = CanvasEvents()
    /// Preview workspace: every artboard of the page, in the open artboard's pixel coordinates (it sits at 0,0).
    /// Panning may then reach any artboard, and "fit all" frames the whole page. nil for motion scenes.
    var board: CGRect?

    var fitScale: CGFloat { ViewZoom.fit(canvas: canvas, view: viewSize, pad: pad) }
    var scale: CGFloat { zoom ?? fitScale }
    var isFit: Bool { zoom == nil }

    func fit() { zoom = nil; pan = .zero }

    /// Sets an absolute scale, keeping the canvas point under `pointer` (viewport coords) fixed.
    func setScale(_ s: CGFloat, at pointer: CGPoint? = nil) {
        let s0 = scale, s1 = ViewZoom.clamp(s, fit: fitScale)
        let p = pointer.map { CGPoint(x: $0.x - viewSize.width / 2, y: $0.y - viewSize.height / 2) } ?? .zero
        let newPan =
            pointer == nil
            ? CGSize(width: pan.width * s1 / max(s0, 1e-6), height: pan.height * s1 / max(s0, 1e-6))
            : ViewZoom.pan(zoomingFrom: s0, to: s1, at: p, pan: pan)
        zoom = s1
        pan = clamped(newPan, scale: s1)
    }

    func zoom(by f: CGFloat, at pointer: CGPoint?) { setScale(scale * f, at: pointer) }

    fileprivate func panBy(_ d: CGSize) {
        if zoom == nil { zoom = fitScale }
        pan = clamped(CGSize(width: pan.width + d.width, height: pan.height + d.height), scale: scale)
    }

    func setPan(_ p: CGSize) {
        if zoom == nil { zoom = fitScale }
        pan = clamped(p, scale: scale)
    }

    private func clamped(_ p: CGSize, scale s: CGFloat) -> CGSize {
        guard let b = board, b.width > canvas.width || b.height > canvas.height || b.minX < 0 || b.minY < 0 else {
            return ViewZoom.clampPan(p, canvas: CGSize(width: canvas.width * s, height: canvas.height * s), view: viewSize)
        }
        return ViewZoom.clampPan(p, board: b, canvas: canvas, scale: s, view: viewSize)
    }

    /// Frames every artboard of the page (⇧1).
    func fitBoard() {
        guard let b = board else { fit(); return }
        let s = ViewZoom.fit(canvas: b.size, view: viewSize, pad: pad)
        zoom = ViewZoom.clamp(s, fit: s)
        // Pan is the open canvas centre's offset from the view centre: put the board's centre in the middle.
        pan = CGSize(width: (canvas.width / 2 - b.midX) * s, height: (canvas.height / 2 - b.midY) * s)
    }

    /// Centres a board rect (an artboard or a selection) at the current zoom, or zooms to it with `zoomIn`.
    func show(_ r: CGRect, zoomIn: Bool = false) {
        let s = zoomIn ? ViewZoom.clamp(ViewZoom.fit(canvas: r.size, view: viewSize, pad: pad * 3)) : scale
        zoom = s
        pan = CGSize(width: (canvas.width / 2 - r.midX) * s, height: (canvas.height / 2 - r.midY) * s)
    }

    /// Canvas pixel under a viewport point.
    func canvasPoint(_ p: CGPoint) -> CGPoint {
        ViewZoom.canvasPoint(p, view: viewSize, canvas: canvas, scale: scale, pan: pan)
    }

    /// Top-left of the canvas in viewport coordinates.
    var canvasOrigin: CGPoint {
        ViewZoom.canvasOrigin(view: viewSize, canvas: canvas, scale: scale, pan: pan)
    }
}

/// Which document's canvas was clicked last (keyboard nudge only acts while the canvas has focus).
enum CanvasFocus {
    static var doc: ObjectIdentifier?
}

/// AppKit event monitor for the viewer: pinch / ⌘-scroll zoom at the pointer, two-finger scroll and
/// middle-drag pan, ⌥-scroll dolly, and canvas focus tracking. Only events over the viewport are consumed.
final class CanvasEvents {
    private var monitor: LocalEventMonitor?
    private var dollyEnd: DispatchWorkItem?
    private var dollying = false

    func install(doc: EditorDocument, vp: ViewportState) {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.scrollWheel, .magnify, .leftMouseDown, .rightMouseDown, .otherMouseDragged]
        let m = LocalEventMonitor(mask) { [weak self, weak doc, weak vp] e in
            guard let self, let doc, let vp else { return e }
            return self.handle(e, doc: doc, vp: vp)
        }
        m.install()
        monitor = m
    }

    func remove() {
        monitor?.remove()
        monitor = nil
    }

    /// Viewport-local point (top-left origin) of an event, or nil when it isn't over the viewport.
    private func local(_ e: NSEvent, _ vp: ViewportState) -> CGPoint? {
        guard let v = vp.anchorView, let w = v.window, e.window === w else { return nil }
        let p = v.convert(e.locationInWindow, from: nil)
        guard v.bounds.contains(p) else { return nil }
        // The floating AI panel sits over the viewport: its scrolls and clicks are its own.
        if FloatingRegions.contains(windowPoint: e.locationInWindow, in: w) { return nil }
        return CGPoint(x: p.x, y: v.isFlipped ? p.y : v.bounds.height - p.y)
    }

    private func handle(_ e: NSEvent, doc: EditorDocument, vp: ViewportState) -> NSEvent? {
        let p = local(e, vp)
        switch e.type {
        case .leftMouseDown, .rightMouseDown:
            if p != nil {
                CanvasFocus.doc = ObjectIdentifier(doc)
            } else if e.window === vp.anchorView?.window, CanvasFocus.doc == ObjectIdentifier(doc) {
                CanvasFocus.doc = nil
            }
            return e
        default: break
        }
        guard let p, !doc.cinema else { return e }
        switch e.type {
        case .magnify:
            vp.zoom(by: 1 + e.magnification, at: p)
            return nil
        case .otherMouseDragged:
            vp.panBy(CGSize(width: e.deltaX, height: e.deltaY))
            return nil
        case .scrollWheel:
            let mods = e.modifierFlags
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 10
            let dx = e.hasPreciseScrollingDeltas ? e.scrollingDeltaX : e.scrollingDeltaX * 10
            if mods.contains(.command) {
                vp.zoom(by: exp(dy * 0.01), at: p)
            } else if mods.contains(.option), doc.canOrbitCamera {
                dolly(doc, factor: Float(exp(-dy * 0.01)))
            } else {
                vp.panBy(CGSize(width: dx, height: dy))
            }
            return nil
        default:
            return e
        }
    }

    /// ⌥-scroll dolly; a burst of scroll events is one undo step.
    private func dolly(_ doc: EditorDocument, factor: Float) {
        if !dollying { doc.beginGesture(); dollying = true }
        doc.dollyCamera(factor: factor)
        dollyEnd?.cancel()
        let w = DispatchWorkItem { [weak self, weak doc] in
            self?.dollying = false; doc?.endGesture()
        }
        dollyEnd = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: w)
    }
}

/// Zero-cost NSView behind the viewport that gives `CanvasEvents` a frame to hit-test against.
struct ViewportAnchor: NSViewRepresentable {
    let vp: ViewportState

    final class PassView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isFlipped: Bool { true }
    }

    func makeNSView(context: Context) -> NSView {
        let v = PassView()
        vp.anchorView = v
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { vp.anchorView = v }
}
