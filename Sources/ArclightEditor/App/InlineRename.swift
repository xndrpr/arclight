import AppKit
import SwiftUI

/// Text that turns into a field on click. Return or clicking anywhere else commits, Esc cancels.
/// The click that ends editing still goes through to whatever was clicked (e.g. the next name to rename).
struct InlineRename: View {
    let text: String
    let placeholder: String
    let bold: Bool
    @Binding var editing: Bool
    var help = ""
    let commit: (String) -> Void
    @State private var hover = false

    var body: some View {
        let font = Font.system(size: 12.5, weight: bold ? .semibold : .regular)
        if editing {
            RenameField(initial: text, placeholder: placeholder, font: font) { result in
                editing = false
                if let n = result, n != text { commit(n) }
            }
            .frame(minWidth: 90, idealWidth: 220, maxWidth: 220)
        } else {
            Text(text).font(font).foregroundStyle(bold ? UI.text : UI.label2).lineLimit(1).truncationMode(.middle)
                .padding(.horizontal, 6).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover ? UI.hover : .clear))
                .barHit()
                .onHover { hover = $0 }
                .onClick { _ in editing = true }  // jitter-tolerant (onTapGesture missed moving trackpad taps)
                .help(help)
                .cursor(.iBeam)
        }
    }
}

/// The editing half of a rename: focuses itself, selects the text, and reports once — the new name
/// (trimmed, non-empty) or nil when cancelled.
struct RenameField: View {
    let initial: String
    let placeholder: String
    var font: Font = UI.font
    let done: (String?) -> Void
    @State private var draft = ""
    @State private var state = RenameState()
    @FocusState private var focused: Bool

    final class RenameState { var finished = false; var cancelled = false }

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain).font(font).foregroundStyle(UI.text)
            .padding(.horizontal, 6).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 5).fill(UI.field))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(UI.accent.opacity(0.6)))
            .background(ClickOutside { finish(save: true, resign: true) })
            .focused($focused)
            .onAppear {
                draft = initial; DispatchQueue.main.async { focused = true }
            }
            .onSubmit { finish(save: true, resign: true) }
            .onExitCommand { finish(save: false, resign: true) }
            // Esc is turned into "leave the field" by the app's key handler; it announces it first.
            .onReceive(NotificationCenter.default.publisher(for: .escapeInTextField)) { _ in
                if focused { state.cancelled = true }
            }
            .onChange(of: focused) { was, now in if was && !now { finish(save: !state.cancelled, resign: false) } }
    }

    private func finish(save: Bool, resign: Bool) {
        guard !state.finished else { return }
        state.finished = true
        if resign { endEditing() }
        let n = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        done(save && !n.isEmpty ? n : nil)
    }
}

/// Calls `action` when the mouse goes down anywhere outside this view (its window or another one).
/// Never consumes the click.
private struct ClickOutside: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let v = MonitorView()
        v.action = action
        return v
    }

    func updateNSView(_ v: MonitorView, context: Context) { v.action = action }

    static func dismantleNSView(_ v: MonitorView, coordinator: ()) { v.stop() }

    final class MonitorView: NSView {
        var action: (() -> Void)?
        private var monitor: LocalEventMonitor?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            let m = LocalEventMonitor([.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] e in
                self?.check(e)
                return e
            }
            m.install()
            monitor = m
        }

        private func check(_ e: NSEvent) {
            guard let w = window else { return }
            if e.window !== w || !bounds.contains(convert(e.locationInWindow, from: nil)) { action?() }
        }

        func stop() {
            monitor?.remove()
            monitor = nil
        }

        deinit { stop() }
    }
}
