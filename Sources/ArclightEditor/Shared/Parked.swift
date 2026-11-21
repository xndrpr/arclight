import AppKit
import SwiftUI

/// Shows `content` in a hosting view of its own that leaves the window while `parked`. A panel hidden this way isn't
/// updated by the changes made meanwhile, and when it comes back it is updated once, from its last state: the
/// timeline hidden behind the Thumbnails workspace no longer follows every artboard edit, and returning to Motion
/// finds it as it was instead of redrawing every row.
struct Parked<Content: View>: NSViewRepresentable {
    let parked: Bool
    @ViewBuilder let content: Content

    final class Coordinator {
        var host: NSHostingView<AnyView>?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let box = NSView()
        if !parked { show(in: box, context.coordinator) }
        return box
    }

    func updateNSView(_ box: NSView, context: Context) {
        let c = context.coordinator
        if parked {
            c.host?.removeFromSuperview()
        } else {
            show(in: box, c)
            c.host?.rootView = AnyView(content.themedRoot())
        }
    }

    private func show(in box: NSView, _ c: Coordinator) {
        let host = c.host ?? NSHostingView(rootView: AnyView(content.themedRoot()))
        host.sizingOptions = []
        c.host = host
        guard host.superview !== box else { return }
        host.frame = box.bounds
        host.autoresizingMask = [.width, .height]
        box.addSubview(host)
    }
}
