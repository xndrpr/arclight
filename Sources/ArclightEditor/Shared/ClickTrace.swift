import AppKit
import ArclightCore
import Foundation
import SwiftUI

/// Help ▸ Record Click Diagnostics: logs every press/release the app receives (time, how far and how long the
/// pointer moved during the press, the view under it) plus every action that fired, to
/// ~/Library/Logs/Arclight/clicks.log. Tells "macOS never sent the click" apart from "the app dropped it".
enum ClickTrace {
    static var enabled: Bool {
        get { Pref.store.bool(forKey: Pref.clickTrace) }
        set { Pref.store.set(newValue, forKey: Pref.clickTrace); if newValue { start() } else { stop() } }
    }
    static var logURL: URL {
        AppPaths.logs.appendingPathComponent("clicks.log")
    }

    /// Observes every event and passes it on unchanged.
    private static let monitor = LocalEventMonitor(.any) { e in
        observe(e); return e
    }
    private static var down: (t: TimeInterval, p: NSPoint)?
    private static var maxMove: CGFloat = 0
    private static var lastMove: (t: TimeInterval, p: NSPoint)?
    private static var speed: CGFloat = 0
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func installIfEnabled() { if enabled { start() } }

    private static func start() {
        guard !monitor.isInstalled else { return }
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        write("— recording started (macOS \(ProcessInfo.processInfo.operatingSystemVersionString)) —")
        monitor.install()
    }

    private static func stop() {
        if monitor.isInstalled { monitor.remove(); write("— recording stopped —") }
    }

    private static func observe(_ e: NSEvent) {
        if e.type == .keyUp, e.keyCode == 49 { write("KEY space up") }
        let p = e.locationInWindow
        // Everything that arrives while a press is in progress (what could cancel it?).
        if down != nil, e.type != .leftMouseUp, e.type != .leftMouseDown {
            let tooltip = NSApp.windows.contains {
                $0.isVisible && String(describing: type(of: $0)).contains("ToolTip")
            }
            write(
                "      during press: \(e.type)\(e.type == .leftMouseDragged ? " Δ\(Int(e.deltaX)),\(Int(e.deltaY))" : "")\(tooltip ? " (tooltip visible)" : "")"
            )
        }
        switch e.type {
        case .mouseMoved, .leftMouseDragged:
            if let l = lastMove, e.timestamp > l.t {
                speed = hypot(p.x - l.p.x, p.y - l.p.y) / CGFloat(e.timestamp - l.t)  // pt/s just before the press
            }
            lastMove = (e.timestamp, p)
            if let d = down { maxMove = max(maxMove, hypot(p.x - d.p.x, p.y - d.p.y)) }
        case .leftMouseDown:
            let moving = (lastMove.map { e.timestamp - $0.t < 0.05 } ?? false) ? Int(speed) : 0
            down = (e.timestamp, p); maxMove = 0
            let tips = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("ToolTip") }
                .count
            let H = e.window?.contentView?.bounds.height ?? 0, W = e.window?.contentView?.bounds.width ?? 0
            write(
                "DOWN  clicks=\(e.clickCount) speed=\(moving)pt/s at x=\(Int(p.x)) y=\(Int(H - p.y)) (from top-left of a \(Int(W))×\(Int(H)) window \"\(e.window?.title ?? "-")\") key=\(e.window?.isKeyWindow ?? false)"
            )
            write("      under pointer: \(hitChain(e))\(tips > 0 ? "  [a tooltip is showing]" : "")")
        case .leftMouseUp:
            let held = down.map { Int((e.timestamp - $0.t) * 1000) } ?? -1
            write("UP    held=\(held)ms moved=\(String(format: "%.1f", maxMove))pt")
            down = nil
        case .rightMouseDown:
            write("RIGHT-DOWN (a two-finger tap while moving becomes a right click)")
        default: break
        }
    }

    /// Something fired (button action, row click…). Call from action sites.
    static func fired(_ what: String) { onFired?(what); if monitor.isInstalled { write("  FIRED \(what)") } }
    /// Space presses: what had focus and whether the app's key handler took the key (if not, AppKit may beep).
    static func key(_ e: NSEvent, handled: Bool) {
        guard monitor.isInstalled else { return }
        let n = debugTypeName
        let kw = NSApp.keyWindow, mw = NSApp.mainWindow
        write(
            "KEY space repeat=\(e.isARepeat) mods=\(e.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue) → \(handled ? "handled" : "PASSED ON (may beep)")"
                + " keyWindow=\(n(kw))\"\(kw?.title ?? "")\" controller=\(n(kw?.windowController)) main=\(n(mw?.windowController))"
                + " firstResponder=\(n(kw?.firstResponder)) sheet=\(kw?.attachedSheet != nil) eventWindow=\(n(e.window))"
        )
    }

    static func note(_ s: String) { if monitor.isInstalled { write("      " + s) } }

    /// Test hook (click probe).
    static var onFired: ((String) -> Void)?

    /// The hit view and its ancestors up to the content view, with frames (window top-left origin).
    private static func hitChain(_ e: NSEvent) -> String {
        guard let w = e.window, let frameView = w.contentView?.superview else { return "-" }
        var v = frameView.hitTest(frameView.convert(e.locationInWindow, from: nil))
        let H = frameView.bounds.height
        var parts: [String] = []
        while let cur = v, parts.count < 8 {
            let r = cur.convert(cur.bounds, to: nil)
            parts.append("\(debugTypeName(cur))[\(Int(r.minX)),\(Int(H - r.maxY)) \(Int(r.width))×\(Int(r.height))]")
            if cur === w.contentView { break }
            v = cur.superview
        }
        return parts.joined(separator: " ← ")
    }

    /// Button press began / ended (SwiftUI registered the press). Called from the shared button styles.
    static func pressed(_ what: String, _ on: Bool) {
        if monitor.isInstalled { write("  \(on ? "PRESS" : "release") \(what)") }
    }

    private static func write(_ s: String) {
        let line = fmt.string(from: Date()) + "  " + s + "\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}

/// `.plain` button look, plus press logging for Record Click Diagnostics.
struct TracedPlainButtonStyle: ButtonStyle {
    let name: String
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, on in ClickTrace.pressed(name, on) }
    }
}
