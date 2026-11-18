import AppKit
import SwiftUI

extension View {
    /// For the content of a `.sheet`: a click on the window the sheet is attached to closes the sheet (AppKit sheets
    /// otherwise just beep). The click is swallowed, so it never also selects or drags anything in the editor.
    func dismissOnOutsideClick(_ isPresented: Binding<Bool>) -> some View {
        background(SheetOutsideClick { isPresented.wrappedValue = false }.frame(width: 0, height: 0))
    }
}

private struct SheetOutsideClick: NSViewRepresentable {
    let dismiss: () -> Void

    func makeNSView(context: Context) -> Probe { Probe(dismiss: dismiss) }
    func updateNSView(_ v: Probe, context: Context) { v.dismiss = dismiss }

    final class Probe: NSView {
        var dismiss: () -> Void
        private var monitor: LocalEventMonitor?

        init(dismiss: @escaping () -> Void) {
            self.dismiss = dismiss
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            monitor?.remove()
            monitor = nil
            guard let sheet = window else { return }
            let m = LocalEventMonitor([.leftMouseDown, .rightMouseDown]) { [weak self, weak sheet] e in
                guard let self, let sheet, let parent = sheet.sheetParent, e.window === parent else { return e }
                self.dismiss()
                return nil
            }
            m.install()
            monitor = m
        }
    }
}
