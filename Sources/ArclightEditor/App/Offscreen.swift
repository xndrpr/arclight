import AppKit
import MetalKit
import SwiftUI

/// Windows for the off-screen `snapshot` and `clickprobe` commands: placed far off-screen, never shown, no Dock icon.
enum Offscreen {
    private static let origin = NSPoint(x: -40000, y: -40000)

    /// Whether this process is an off-screen `snapshot` or `clickprobe` run. Endless animations (status-dot pulses)
    /// stay still then, so a capture doesn't depend on when it lands in the animation.
    private(set) static var isActive = false
    private static var usesThrowawayStore = false
    /// The settings domain of an off-screen run (`Pref.store`), in the temp folder.
    static let throwawayFolder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "arclight-offscreen-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")

    /// AppKit without a Dock icon or a menu bar.
    @discardableResult
    static func startApp() -> NSApplication {
        isActive = true
        // Off-screen commands never read or write the user's settings: a throwaway domain, removed at exit.
        if !usesThrowawayStore {
            usesThrowawayStore = true
            if let d = Pref.throwawayStore(in: throwawayFolder) { Pref.store = d }
            atexit { try? FileManager.default.removeItem(at: Offscreen.throwawayFolder) }
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        return app
    }

    /// Opens a project without adding it to Open Recent.
    static func openDocument(_ path: String) throws -> EditorDocument {
        EditorDocument.recordRecents = false
        return try EditorDocument(url: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    static func window(_ size: NSSize, style: NSWindow.StyleMask = [.borderless]) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(origin: origin, size: size), styleMask: style, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        return w
    }

    /// Makes `root` (themed) the window's content, in an `AppHostingView` like every app window.
    @discardableResult
    static func host<V: View>(_ root: V, in w: NSWindow) -> NSView {
        let host = AppHostingView(rootView: root.themedRoot())
        host.frame = NSRect(origin: .zero, size: w.contentRect(forFrameRect: w.frame).size)
        w.contentView = host
        return host
    }

    /// A titled window set up like the editor's (transparent title bar, compact unified toolbar), to see what
    /// receives clicks in the title-bar row. Snapshots have no title bar.
    static func titledWindow<V: View>(_ size: NSSize, fillsTitlebar: Bool = false, content: V) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(origin: origin, size: size), styleMask: AppWindows.editorStyle, backing: .buffered,
            defer: false)
        AppWindows.configure(w, fillsTitlebar: fillsTitlebar, content: content)
        AppWindows.addTitlebarToolbar(to: w, identifier: "probe")
        return w
    }

    /// Runs the main run loop for `seconds`, calling `each` after every `step`.
    static func pump(_ seconds: Double, step: Double = 0.005, each: () -> Void = {}) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(step)); each() }
    }

    /// Draws `host` into a bitmap until three drawings in a row, `interval` apart with the run loop and layout running
    /// in between, are identical, or `limit` seconds pass; returns the last drawing. A fixed wait isn't enough on a
    /// loaded machine: thumbnails arrive late and a drawing can catch text fields before their last layout pass.
    static func settledDrawing(_ host: NSView, interval: Double = 0.25, limit: Double = 10) -> NSBitmapImageRep? {
        func draw() -> NSBitmapImageRep? {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
            host.cacheDisplay(in: host.bounds, to: rep)
            return rep
        }
        func same(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Bool {
            guard let pa = a.bitmapData, let pb = b.bitmapData, a.bytesPerRow == b.bytesPerRow,
                a.pixelsHigh == b.pixelsHigh
            else { return false }
            return memcmp(pa, pb, a.bytesPerRow * a.pixelsHigh) == 0
        }
        let end = Date().addingTimeInterval(limit)
        var last = draw(), unchanged = 0
        while unchanged < 2 && Date() < end {
            pump(interval, step: 0.05) { host.layoutSubtreeIfNeeded() }
            let next = draw()
            if let a = last, let b = next, same(a, b) { unchanged += 1 } else { unchanged = 0 }
            last = next
        }
        if unchanged < 2 {
            FileHandle.standardError.write("snapshot: the view didn't settle in \(limit) s\n".data(using: .utf8)!)
        }
        return last
    }

    /// The view as drawn (`drawing`, or drawn now), with the Metal viewport (which view caching can't capture)
    /// rendered at `time` and composited in, and the floating AI panel drawn again on top of it.
    static func capture(
        _ host: NSView, in w: NSWindow, size: NSSize, doc: EditorDocument, time: Double,
        drawing: NSBitmapImageRep? = nil
    ) -> NSImage? {
        guard let rep = drawing ?? host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        if drawing == nil { host.cacheDisplay(in: host.bounds, to: rep) }
        let image = NSImage(size: size)
        image.lockFocus()
        rep.draw(in: NSRect(origin: .zero, size: size))
        if let mtk = find(MTKView.self, in: host), mtk.bounds.width > 4,
            let frame = try? doc.renderer.image(
                scene: doc.scene, project: doc.project, assets: doc.assets, time: time,
                scale: Double(mtk.bounds.width) * 2 / Double(doc.canvasSize.width))
        {
            var r = mtk.convert(mtk.bounds, to: host)
            if host.isFlipped { r.origin.y = host.bounds.height - r.maxY }  // the image context is y-up
            NSGraphicsContext.current?.cgContext.draw(frame, in: r)
            if let p = FloatingRegions.rect(for: w) {
                let pr = NSRect(x: p.minX, y: size.height - p.maxY, width: p.width, height: p.height)
                    .intersection(NSRect(origin: .zero, size: size))
                rep.draw(in: pr, from: pr, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
            }
        }
        image.unlockFocus()
        return image
    }

    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff) else { return nil }
        return bmp.representation(using: .png, properties: [:])
    }

    static func find<T: NSView>(_ type: T.Type, in v: NSView) -> T? {
        if let t = v as? T { return t }
        for s in v.subviews { if let f = find(type, in: s) { return f } }
        return nil
    }
}

/// Synthetic mouse events sent straight to one window, with increasing timestamps.
final class SyntheticMouse {
    private let window: NSWindow
    private var time = ProcessInfo.processInfo.systemUptime

    init(_ window: NSWindow) { self.window = window }

    /// `after`: seconds since the previous event (0 sends both with the same timestamp, like a fast tap-to-click).
    @discardableResult
    func send(_ type: NSEvent.EventType, _ p: NSPoint, after dt: Double, clickCount: Int, pressure: Float = 1) -> Bool {
        time += dt
        guard
            let e = NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clickCount, pressure: pressure)
        else { return false }
        window.sendEvent(e)
        return true
    }
}

/// The class name of a view, window or controller without generic parameters (`NSHostingView<…>` → `NSHostingView`),
/// or "nil". For diagnostics output.
func debugTypeName(_ o: Any?) -> String {
    guard let o else { return "nil" }
    return String(describing: type(of: o)).replacingOccurrences(of: "<.*", with: "", options: .regularExpression)
}
