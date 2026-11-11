import AppKit
import SwiftUI

/// `arclight clickprobe`: development checks for "clicks while the pointer moves don't register". Each probe builds
/// an off-screen window, replays real NSEvent sequences into it and prints what fired. Nothing is shown on screen.
/// This file: the app's button kinds in isolation; ClickProbe+Editor.swift: the real editor.
public enum ClickProbe {
    final class Counter: ObservableObject {
        @Published var hits: [String: Int] = [:]
        func hit(_ k: String) { hits[k, default: 0] += 1 }
    }

    /// One of each button kind, 30 pt rows 50 pt apart.
    struct Probe: View {
        @ObservedObject var c: Counter
        var top: CGFloat = 20
        @State private var hover = false
        var body: some View {
            VStack(alignment: .leading, spacing: 20) {
                Button("plain") { c.hit("plain") }.buttonStyle(.plain).frame(width: 120, height: 30).hitArea()
                IconButton(symbol: "gear", help: "icon") { c.hit("icon") }.frame(width: 120, height: 30)
                Button("pill") { c.hit("pill") }.buttonStyle(PillButtonStyle()).frame(width: 120, height: 30)
                Text("onClick").frame(width: 120, height: 30).hitArea().onClick { _ in c.hit("onClick") }
                // The gesture `.onClick` replaces, kept here to show the difference.
                Text("tap").frame(width: 120, height: 30).hitArea().onTapGesture { c.hit("tap") }
                Button("hoverPlain") { c.hit("hoverPlain") }.buttonStyle(.plain).frame(width: 120, height: 30)
                    .background(hover ? UI.hover : .clear).hitArea().onHover { hover = $0 }.cursor(.pointingHand).help(
                        "x")
            }
            .padding(.horizontal, 20).padding(.top, top).padding(.bottom, 20).frame(
                width: 300, height: 400, alignment: .topLeading)
        }
    }

    /// Clicks every button kind with moving / jittery / zero-length presses (the ways trackpad tap-to-click arrives).
    public static func run(titled: Bool = false) -> Int32 {
        Offscreen.startApp()
        let c = Counter()
        let w = Offscreen.window(
            NSSize(width: 300, height: 400),
            style: titled ? [.titled, .closable, .resizable, .fullSizeContentView] : [.borderless])
        if titled { w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden }
        let host = Offscreen.host(Probe(c: c, top: titled ? 0 : 20), in: w)
        w.orderFrontRegardless()
        Offscreen.pump(0.5)
        host.layoutSubtreeIfNeeded()

        let names = ["plain", "icon", "pill", "onClick", "tap", "hoverPlain"]
        let top0: CGFloat = titled ? 0 : 20
        // Row centre, from the host's top-left, in window coordinates.
        func centre(_ i: Int) -> NSPoint {
            let yTop = top0 + 15 + CGFloat(i) * 50
            let local = NSPoint(x: 80, y: host.isFlipped ? yTop : host.bounds.height - yTop)
            return host.convert(local, to: nil)
        }
        print("window \(w.frame.size), content \(host.bounds.size), first row at \(centre(0))")

        let mouse = SyntheticMouse(w)
        var step = 0.008
        func send(_ type: NSEvent.EventType, _ p: NSPoint) {
            mouse.send(type, p, after: step, clickCount: type == .mouseMoved ? 0 : 1)
        }

        // (label, moves before the press without a pause, drag distance during the press, pause before the press)
        let scenarios: [(String, Bool, CGFloat, Double)] = [
            ("still", false, 0, 0.3), ("moving-in, no drag", true, 0, 0), ("moving, drag 2pt", true, 2, 0),
            ("moving, drag 5pt", true, 5, 0), ("moving, drag 10pt", true, 10, 0), ("still, drag 5pt", false, 5, 0.3),
            ("0ms tap", true, 0, -1),
        ]
        var failures = 0
        for (label, moving, drag, pause) in scenarios {
            var line = label.padding(toLength: 22, withPad: " ", startingAt: 0)
            for (i, n) in names.enumerated() {
                let before = c.hits[n, default: 0]
                let p = centre(i)
                for k in stride(from: 6, through: 0, by: -1) {
                    send(.mouseMoved, NSPoint(x: p.x - CGFloat(k) * 8, y: p.y)); if !moving { Offscreen.pump(0.01) }
                }
                if pause > 0 { Offscreen.pump(pause) }
                if pause < 0 { step = 0 }  // down and up with the same timestamp, back to back (seen from tap-to-click)
                send(.leftMouseDown, p)
                if drag > 0 {
                    for k in 1...3 { send(.leftMouseDragged, NSPoint(x: p.x + drag * CGFloat(k) / 3, y: p.y)) }
                }
                send(.leftMouseUp, NSPoint(x: p.x + drag, y: p.y))
                step = 0.008
                // keeps moving after release
                for k in 1...4 { send(.mouseMoved, NSPoint(x: p.x + drag + CGFloat(k) * 8, y: p.y)) }
                Offscreen.pump(0.15)
                let ok = c.hits[n, default: 0] > before
                if !ok { failures += 1 }
                line += " \(n)=\(ok ? "✓" : "✗")"
                send(.mouseMoved, NSPoint(x: 280, y: 5)); Offscreen.pump(0.1)
            }
            print(line)
        }
        print(failures == 0 ? "all clicks registered" : "\(failures) click(s) lost")
        return failures == 0 ? 0 : 1
    }

    /// Reproduces the lost-click bug: press, a zero-movement trackpad scroll ("may begin"), release.
    /// "with guard" drops that scroll the way `ScrollClickGuard` does in the app.
    public static func scrollCancel() -> Int32 {
        Offscreen.startApp()
        let c = Counter()
        let size = NSSize(width: 300, height: 400)
        let w = Offscreen.window(size)
        Offscreen.host(Probe(c: c), in: w)
        w.orderFrontRegardless()
        Offscreen.pump(0.5)
        let names = ["plain", "icon", "pill", "onClick"]
        let mouse = SyntheticMouse(w)
        func mayBeginScroll(_ p: NSPoint) -> NSEvent? {
            guard
                let cg = CGEvent(
                    scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)
            else { return nil }
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: 128)  // kCGScrollPhaseMayBegin
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            let screen = w.convertPoint(toScreen: p)
            cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
            return NSEvent(cgEvent: cg)
        }
        for guarded in [false, true] {
            var line = guarded ? "with guard:    " : "without guard: "
            for (i, n) in names.enumerated() {
                let p = NSPoint(x: 80, y: size.height - (20 + 15 + CGFloat(i) * 50))
                let before = c.hits[n, default: 0]
                mouse.send(.mouseMoved, p, after: 0.008, clickCount: 1); Offscreen.pump(0.05)
                mouse.send(.leftMouseDown, p, after: 0.008, clickCount: 1); Offscreen.pump(0.004)
                if let s = mayBeginScroll(p) {
                    let drop =
                        guarded
                        && ScrollClickGuard.shouldDrop(
                            buttonDown: true, dx: s.scrollingDeltaX, dy: s.scrollingDeltaY,
                            phase: s.phase, momentum: s.momentumPhase)
                    if !drop { w.sendEvent(s) }
                }
                Offscreen.pump(0.004)
                mouse.send(.leftMouseUp, p, after: 0.008, clickCount: 1); Offscreen.pump(0.1)
                line += " \(n)=\(c.hits[n, default: 0] > before ? "✓" : "✗")"
            }
            print(line)
        }
        return 0
    }
}
