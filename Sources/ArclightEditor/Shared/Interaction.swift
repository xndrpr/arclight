import AppKit
import SwiftUI

/// Click-vs-drag decision shared by every custom pointer gesture (canvas, timeline, ruler, audio lane, layer rows).
///
/// Trackpad tap-to-click sends mouse-down and mouse-up within a few milliseconds while the finger is often
/// still moving, so the pointer can travel several points between them. A press only becomes a drag once it
/// has clearly moved: more than `slop` points after `settle` seconds, or more than `fastSlop` points at once.
/// Anything less is a click when released.
enum ClickSlop {
    static let slop: CGFloat = 4
    static let fastSlop: CGFloat = 12
    static let settle: TimeInterval = 0.12

    static func isDrag(distance: CGFloat, elapsed: TimeInterval) -> Bool {
        distance >= fastSlop || (distance >= slop && elapsed >= settle)
    }

    static func distance(_ t: CGSize) -> CGFloat { hypot(t.width, t.height) }
}

/// Tracks one press (mouse-down … mouse-up) and latches to "dragging" once `ClickSlop` says so.
struct PressTracker {
    private(set) var start: Date?
    private(set) var dragging = false

    var isPressed: Bool { start != nil }

    mutating func begin(now: Date = Date()) { start = now; dragging = false }

    /// Feed the translation since mouse-down; returns true once the press is a drag (and stays true).
    @discardableResult
    mutating func update(_ translation: CGSize, now: Date = Date()) -> Bool {
        guard let s = start else { return false }
        if !dragging, ClickSlop.isDrag(distance: ClickSlop.distance(translation), elapsed: now.timeIntervalSince(s)) {
            dragging = true
        }
        return dragging
    }

    /// Ends the press; returns true when it was a click (never became a drag).
    mutating func end() -> Bool {
        defer { start = nil; dragging = false }
        return start != nil && !dragging
    }
}

extension View {
    /// Click handler for rows and other non-button areas, tolerant of tap-to-click jitter (SwiftUI's
    /// `onTapGesture` / `TapGesture(count: 2)` give up as soon as the pointer moves a few points between down and up,
    /// which a moving finger on the trackpad always does). `action` gets AppKit's click count (2 = double-click) and
    /// fires on every click, so a double-click runs the single-click action first, like AppKit.
    /// `enabled: false` lets the subviews (e.g. an inline rename field) have the clicks instead.
    func onClick(enabled: Bool = true, _ action: @escaping (Int) -> Void) -> some View {
        modifier(ClickModifier(enabled: enabled, action: action))
    }
}

private struct ClickModifier: ViewModifier {
    let enabled: Bool
    let action: (Int) -> Void
    @State private var press = PressTracker()

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if !press.isPressed { press.begin() }
                    press.update(g.translation)
                }
                .onEnded { g in
                    let click = press.isPressed ? press.end() : ClickSlop.distance(g.translation) < ClickSlop.fastSlop
                    if click {
                        ClickTrace.fired("row click"); action(max(1, NSApp.currentEvent?.clickCount ?? 1))
                    } else {
                        ClickTrace.fired(
                            "row press treated as drag (moved \(Int(ClickSlop.distance(g.translation)))pt)")
                    }
                }, including: enabled ? .all : .subviews)
    }
}

/// `withAnimation` that respects reduced motion.
func withMotion(_ a: Animation, _ body: () -> Void) {
    if Motion.reduce { body() } else { withAnimation(a, body) }
}

/// Selection / gizmo colours that stay visible over any video content: the app accent, drawn over a thin
/// contrasting halo (dark under light accents, light under dark ones).
enum OverlayInk {
    static var line: Color { UI.accent }
    static var halo: Color { UI.isDark ? Color.black.opacity(0.55) : Color.white.opacity(0.7) }
    /// Label chips (layer id tag, value readout).
    static var chip: Color { UI.accent }
    static var chipText: Color { UI.onAccent }
}

extension Shape {
    /// Stroke in the overlay ink with a 3 px halo underneath.
    func overlayStroke(_ width: CGFloat = 1, dash: [CGFloat] = [], opacity: Double = 1) -> some View {
        ZStack {
            stroke(OverlayInk.halo.opacity(opacity), style: StrokeStyle(lineWidth: width + 2, dash: dash))
            stroke(OverlayInk.line.opacity(opacity), style: StrokeStyle(lineWidth: width, dash: dash))
        }
    }
}

/// Trackpad "scroll may begin" events must not cancel clicks.
///
/// Touching the trackpad (tap-to-click included) makes macOS send a scroll-wheel event with no movement
/// (phase `.mayBegin`, then `.cancelled`). When one lands between mouse-down and mouse-up, SwiftUI treats it as the
/// start of a scroll and cancels the pressed button, so the click silently does nothing; one that lands just before
/// the press does the same inside scroll views. So: zero-movement scroll events during a press are dropped, and a
/// "may begin" outside a press is held back for a moment and dropped if a press follows (a tap is landing),
/// delivered otherwise. Real scrolling, momentum and mouse wheels are untouched.
///
/// The press is tracked from the mouse events themselves: `NSEvent.pressedMouseButtons` reports the physical button,
/// which a tap-to-click never presses, so taps went unguarded (click diagnostics: a quarter of the taps with a scroll
/// event mid-press were lost, against one in eight without).
enum ScrollClickGuard {
    private static var pressed = false
    /// The held "may begin" event, and whether the last one was dropped for a tap (its `.cancelled` goes too).
    private static var held: NSEvent?
    private static var droppedTouch = false
    private static var lastMomentum: TimeInterval = 0
    static let hold: TimeInterval = 0.2

    /// Installed once at launch and never removed.
    private static let buttons = LocalEventMonitor([.leftMouseDown, .leftMouseUp]) { e in
        pressed = e.type == .leftMouseDown
        if pressed, held != nil {
            held = nil
            droppedTouch = true
            ClickTrace.note("dropped a trackpad touch just before the press (would have cancelled the click)")
        }
        return e
    }

    private static let scrolls = LocalEventMonitor(.scrollWheel) { e in
        if !e.momentumPhase.isEmpty { lastMomentum = e.timestamp }
        if shouldDrop(e) {
            ClickTrace.note("dropped a zero-movement trackpad scroll during the press (would have cancelled the click)")
            return nil
        }
        let still = e.scrollingDeltaX == 0 && e.scrollingDeltaY == 0 && e.momentumPhase.isEmpty
        if still, e.phase.contains(.cancelled), droppedTouch {
            droppedTouch = false
            return nil
        }
        // A touch while a flick is still coasting stops it: that one goes through at once.
        if still, e.phase.contains(.mayBegin), e.timestamp - lastMomentum > 0.5 {
            deliverHeld()
            held = e
            DispatchQueue.main.asyncAfter(deadline: .now() + hold) { if held === e { deliverHeld() } }
            return nil
        }
        deliverHeld()  // a real scroll follows its touch, in order
        return e
    }

    private static func deliverHeld() {
        guard let h = held else { return }
        held = nil
        NSApp.sendEvent(h)
    }

    static func install() {
        buttons.install()
        scrolls.install()
    }

    static func shouldDrop(_ e: NSEvent) -> Bool {
        shouldDrop(
            buttonDown: pressed, dx: e.scrollingDeltaX, dy: e.scrollingDeltaY, phase: e.phase,
            momentum: e.momentumPhase)
    }

    /// Pure rule (tested): drop while the button is down, unless the event actually scrolls.
    static func shouldDrop(
        buttonDown: Bool, dx: CGFloat, dy: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase
    ) -> Bool {
        guard buttonDown, momentum.isEmpty else { return false }
        if phase.contains(.mayBegin) || phase.contains(.cancelled) { return true }
        return dx == 0 && dy == 0
    }
}
