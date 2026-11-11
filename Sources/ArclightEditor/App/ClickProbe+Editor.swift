import AppKit
import Combine
import SwiftUI

/// Click probes against the real editor (`arclight clickprobe <subcommand> <project>`).
extension ClickProbe {
    private static let editorSize = NSSize(width: 1400, height: 900)

    /// The editor in a borderless off-screen window, settled.
    private static func borderlessEditor(_ project: String) -> (EditorDocument, NSWindow)? {
        Offscreen.startApp()
        guard let doc = try? Offscreen.openDocument(project) else { return nil }
        let w = Offscreen.window(editorSize)
        Offscreen.host(EditorView(doc: doc), in: w)
        w.orderFrontRegardless()
        Offscreen.pump(1.5)
        return (doc, w)
    }

    /// Sweeps the pointer over the whole window and counts document change notifications (each one re-renders
    /// every view observing the document). Mouse moves alone should cause none.
    public static func runEditor(project: String) -> Int32 {
        guard let (doc, w) = borderlessEditor(project) else { return 1 }
        var changes = 0
        let sub = doc.objectWillChange.sink { changes += 1 }
        Offscreen.pump(1.0)
        let idle = changes
        changes = 0
        let mouse = SyntheticMouse(w)
        var moves = 0
        for y in stride(from: 20.0, to: Double(editorSize.height) - 20, by: 40) {
            for x in stride(from: 10.0, to: Double(editorSize.width) - 10, by: 12) {
                if mouse.send(.mouseMoved, NSPoint(x: x, y: y), after: 0.008, clickCount: 0, pressure: 0) { moves += 1 }
                RunLoop.main.run(until: Date().addingTimeInterval(0.001))
            }
        }
        Offscreen.pump(0.3)
        print("idle (1 s, no input): \(idle) document changes")
        print("pointer sweep (\(moves) moves): \(changes) document changes")
        sub.cancel()
        return 0
    }

    /// What receives a click in the title-bar row of an editor-style window: should be our hosting view, not
    /// AppKit's title bar.
    public static func titlebarHits() -> Int32 {
        Offscreen.startApp()
        let w = Offscreen.titledWindow(
            NSSize(width: 1200, height: 700),
            content: VStack(spacing: 0) {
                HStack {
                    Button("A") {}; Spacer(); Button("B") {}
                }.frame(height: 38).background(Color.red)
                Spacer()
            }.ignoresSafeArea(.container, edges: .top))
        w.orderFrontRegardless()
        Offscreen.pump(0.5)
        let frameView = w.contentView!.superview!
        print("title-bar row height: \(w.frame.height - w.contentLayoutRect.height)")
        for x in [10.0, 100, 600, 1150] {
            for yTop in [5.0, 19, 33] {
                let v = frameView.hitTest(frameView.convert(NSPoint(x: x, y: w.frame.height - yTop), from: nil))
                print("x=\(Int(x)) y=\(Int(yTop)) from top → \(debugTypeName(v))")
            }
        }
        let zoom = w.standardWindowButton(.zoomButton)!
        print("zoom button frame in window: \(zoom.convert(zoom.bounds, to: nil))")
        return 0
    }

    /// The editor in a titled window (as the app makes it): which view receives clicks in the top bar and the
    /// sidebar tab strip. `noSafeArea` lays the content out without a title-bar safe area (`fillsTitlebar`).
    public static func editorHits(project: String, noSafeArea: Bool) -> Int32 {
        Offscreen.startApp()
        guard let doc = try? Offscreen.openDocument(project) else { return 1 }
        if ProcessInfo.processInfo.environment["PROBE_AI"] != nil {
            UserDefaults.standard.setVolatileDomain([Pref.aiPanel: true], forName: UserDefaults.argumentDomain)
        }
        let w = Offscreen.titledWindow(editorSize, fillsTitlebar: noSafeArea, content: EditorView(doc: doc))
        w.orderFrontRegardless()
        Offscreen.pump(1.5)
        let frameView = w.contentView!.superview!
        let H = w.frame.height
        func viewName(_ x: Double, _ yTop: Double) -> String {
            debugTypeName(frameView.hitTest(frameView.convert(NSPoint(x: x, y: H - yTop), from: nil)))
        }
        for yTop in [2.0, 8, 14, 20, 26, 32, 36, 40, 46, 52, 60, 70] {
            var runs: [(String, Int, Int)] = []
            for x in stride(from: 0, to: Int(w.frame.width), by: 8) {
                let n = viewName(Double(x), yTop)
                if let l = runs.last, l.0 == n { runs[runs.count - 1].2 = x } else { runs.append((n, x, x)) }
            }
            print("y=\(Int(yTop)): " + runs.map { "\($0.1)-\($0.2) \($0.0)" }.joined(separator: " | "))
        }
        var bad = 0
        for (label, x, yTop) in [
            ("top bar: AI pill", 760.0, 19.0), ("top bar: Performance", 1170, 19), ("top bar: gear", 1300, 19),
            ("top bar: Export", 1360, 19), ("top bar: top edge right", 1300, 4), ("tabs: History", 110, 58),
            ("tabs: Assets", 180, 50), ("inspector: search", 1200, 62), ("transport: zoom", 900, 520),
        ] {
            let n = viewName(x, yTop)
            if n.contains("Clip") || n.contains("Scroll") { bad += 1 }
            print("\(label.padding(toLength: 26, withPad: " ", startingAt: 0)) → \(n)")
        }
        print(bad == 0 ? "no scroll views over controls" : "\(bad) control(s) covered by a scroll view")
        return 0
    }

    /// Clicks every point of a horizontal band many times with tap-like timing and reports spots where the same
    /// click sometimes fires an icon button and sometimes doesn't.
    public static func editorRepeat(project: String, yTop: Double, x0: Double, x1: Double) -> Int32 {
        guard let (_, w) = borderlessEditor(project) else { return 1 }
        var fired: [String] = []
        ClickTrace.onFired = { fired.append($0) }
        let mouse = SyntheticMouse(w)
        func send(_ type: NSEvent.EventType, _ p: NSPoint, dt: Double) {
            mouse.send(type, p, after: dt, clickCount: type == .mouseMoved ? 0 : 1)
        }
        var flaky = 0
        for x in stride(from: x0, through: x1, by: 4) {
            let p = NSPoint(x: x, y: editorSize.height - yTop)
            var results: [String] = []
            for trial in 0..<6 {
                fired = []
                for k in stride(from: 5, through: 1, by: -1) {
                    send(.mouseMoved, NSPoint(x: p.x - Double(k) * 6, y: p.y), dt: 0.008)
                }
                if trial % 3 == 0 { Offscreen.pump(0.02) }
                send(.leftMouseDown, p, dt: 0.004)
                if trial % 2 == 0 { Offscreen.pump(0.016) }
                send(.leftMouseUp, p, dt: trial % 2 == 0 ? 0.016 : 0)
                Offscreen.pump(trial % 3 == 2 ? 0.05 : 0.3)
                results.append(fired.first ?? "-")
            }
            let hits = Set(results)
            if hits.count > 1 {
                flaky += 1; print("x=\(Int(x)) y=\(Int(yTop)) INCONSISTENT: \(results)")
            } else if let h = hits.first, h != "-" {
                print("x=\(Int(x)) ok \(h)")
            }
        }
        print(flaky == 0 ? "consistent" : "\(flaky) flaky spot(s)")
        return 0
    }

    /// Clickable-area map: one tap per grid point, printing which action fired as a letter ("." = nothing). Shows
    /// the real hit rectangles of buttons against how they look. Only buttons that call `ClickTrace.fired` show up.
    public static func editorGrid(
        project: String, y0: Double, y1: Double, x0: Double, x1: Double, step: Double
    ) -> Int32 {
        guard let (_, w) = borderlessEditor(project) else { return 1 }
        var fired: String?
        ClickTrace.onFired = { fired = $0 }
        var legend: [String: Character] = [:]
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
        let mouse = SyntheticMouse(w)
        print("x from \(Int(x0)) to \(Int(x1)) step \(Int(step))")
        for y in stride(from: y0, through: y1, by: step) {
            var row = ""
            for x in stride(from: x0, through: x1, by: step) {
                fired = nil
                let p = NSPoint(x: x, y: editorSize.height - y)
                for type in [NSEvent.EventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
                    mouse.send(type, p, after: 0.01, clickCount: 1)
                }
                Offscreen.pump(0.03)
                if let f = fired {
                    if legend[f] == nil { legend[f] = letters[legend.count % letters.count] }
                    row.append(legend[f]!)
                } else {
                    row.append(".")
                }
            }
            print(String(format: "y=%3d ", Int(y)) + row)
        }
        for (k, v) in legend.sorted(by: { $0.value < $1.value }) { print("\(v) = \(k)") }
        return 0
    }

    /// Dumps the AppKit views SwiftUI placed inside the editor (class, frame from the window's top-left), to find
    /// platform views that sit over controls and take their clicks. PROBE_ACTIVE=1 makes the window key first.
    public static func editorViews(project: String) -> Int32 {
        let app = Offscreen.startApp()
        guard let doc = try? Offscreen.openDocument(project) else { return 1 }
        let w = Offscreen.titledWindow(editorSize, content: EditorView(doc: doc))
        if ProcessInfo.processInfo.environment["PROBE_ACTIVE"] != nil {
            app.setActivationPolicy(.accessory)
            app.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        } else {
            w.orderFrontRegardless()
        }
        Offscreen.pump(1.5)
        // Hover the sidebar tabs and top bar like a user would, long enough for tooltips.
        let mouse = SyntheticMouse(w)
        for (x, y) in [(40.0, 58.0), (100, 58), (160, 58), (780, 19), (1200, 19)] {
            mouse.send(.mouseMoved, NSPoint(x: x, y: w.frame.height - y), after: 0.01, clickCount: 0, pressure: 0)
            Offscreen.pump(1.2)
        }
        print("key=\(w.isKeyWindow) active=\(app.isActive)")
        let H = w.frame.height
        func walk(_ v: NSView, _ depth: Int) {
            let r = v.convert(v.bounds, to: nil)
            if depth > 0 {
                print(
                    String(repeating: "  ", count: depth)
                        + "\(debugTypeName(v)) x=\(Int(r.minX)) y=\(Int(H - r.maxY)) w=\(Int(r.width)) h=\(Int(r.height))\(v.isHidden ? " hidden" : "")"
                )
            }
            for s in v.subviews { walk(s, depth + 1) }
        }
        walk(w.contentView!, 0)
        return 0
    }
}
