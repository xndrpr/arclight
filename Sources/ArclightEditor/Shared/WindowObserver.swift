import AppKit
import SwiftUI

/// Reports the hosting window when attached, and again when it enters/leaves full screen or resizes.
struct WindowObserver: NSViewRepresentable {
    let changed: (NSWindow?) -> Void

    func makeNSView(context: Context) -> ObserverView {
        let v = ObserverView()
        v.changed = changed
        return v
    }

    func updateNSView(_ v: ObserverView, context: Context) { v.changed = changed }

    final class ObserverView: NSView {
        var changed: ((NSWindow?) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            let w = window
            DispatchQueue.main.async { [weak self] in self?.changed?(w) }
            guard let w else { return }
            for name in [
                NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification,
                NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification, NSWindow.didChangeScreenNotification,
            ] {
                tokens.append(
                    NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                        self?.changed?(self?.window)
                        // Full-screen transitions update the style mask and button windows after the notification.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                            self?.changed?(self?.window)
                        }
                    })
            }
        }

        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}
