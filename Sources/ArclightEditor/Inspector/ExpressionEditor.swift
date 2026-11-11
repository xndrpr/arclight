import AppKit
import ArclightCore
import SwiftUI

/// An expression in a field: one-line preview + inline compile error + value at the playhead. Click to edit.
struct ExprField: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot
    let source: String
    @Binding var open: Bool

    var body: some View {
        let error = doc.exprError(source)
        VStack(alignment: .leading, spacing: 2) {
            Button {
                open = true
            } label: {
                HStack(spacing: 6) {
                    Text("ƒx").font(.system(size: 10.5, weight: .semibold, design: .serif)).italic().foregroundStyle(
                        UI.dim)
                    Text(source.replacingOccurrences(of: "\n", with: " ")).font(UI.mono).foregroundStyle(UI.text)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .fieldChrome(border: error == nil ? UI.fieldBorder : UI.danger.opacity(0.7))
            }
            .buttonStyle(.plain).cursor(.pointingHand).help(source)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 10.5)).foregroundStyle(
                    UI.danger
                )
                .lineLimit(2).help(error + "\nClick the field to fix it.")
            } else {
                Text("= " + ExpressionEditor.valueText(doc, slot, source)).font(UI.monoSmall).foregroundStyle(UI.faint)
                    .lineLimit(1)
            }
        }
        .popover(isPresented: $open, arrowEdge: .leading) {
            ExpressionEditor(doc: doc, slot: slot, initial: source, close: { open = false })
        }
    }
}

private struct ExpressionEditor: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot
    let initial: String
    let close: () -> Void
    @State private var draft = ""
    @StateObject private var editor = CodeEditorController()

    struct Helper { let insert: String; let doc: String }
    static let variables: [Helper] = [
        Helper(insert: "t", doc: "Layer time in seconds (from its in point)"),
        Helper(insert: "T", doc: "Scene time in seconds"),
        Helper(insert: "d", doc: "Scene duration"),
        Helper(insert: "i", doc: "Copy index (repeater instance)"),
        Helper(insert: "n", doc: "Number of copies"),
    ]
    static let functions: [Helper] = [
        Helper(insert: "ease(\"outExpo\", clamp(t / 0.6, 0, 1))", doc: "Named easing of 0…1"),
        Helper(insert: "smoothstep(0, 1, t)", doc: "Smooth 0→1 between two times"),
        Helper(insert: "clamp(x, 0, 1)", doc: "Limit to a range"),
        Helper(insert: "lerp(0, 100, u)", doc: "Mix two values"),
        Helper(insert: "wiggle(2, 10)", doc: "Random motion: frequency, amount"),
        Helper(insert: "rand(i)", doc: "Stable random 0…1 per seed"),
        Helper(insert: "noise(t)", doc: "Smooth random 0…1"),
        Helper(insert: "Math.sin(t * 2) * 20", doc: "Oscillate"),
        Helper(insert: "lamp(t, 0.5)", doc: "Lamp switching on at a time, with flicker"),
        Helper(insert: "pick(i, n, 0.45, 1)", doc: "Rank of a randomly chosen share of copies (−1 if not chosen)"),
        Helper(insert: "litCount(\"crowd\")", doc: "Lit copies in a repeater"),
        Helper(insert: "litFraction(\"crowd\")", doc: "Share of lit copies 0…1"),
        Helper(insert: "instanceCount(\"crowd\")", doc: "Copies in a repeater"),
    ]

    var body: some View {
        let error = doc.exprError(draft)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(slot.field.label + " — expression").font(.system(size: 12, weight: .semibold)).foregroundStyle(
                    UI.text)
                Spacer()
                Text(slot.field.kind.name).font(UI.monoSmall).foregroundStyle(UI.faint)
            }
            HStack(alignment: .top, spacing: 10) {
                CodeTextView(text: $draft, controller: editor)
                    .frame(width: 380, height: 180)
                    .background(RoundedRectangle(cornerRadius: 6).fill(UI.field))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6).stroke(error == nil ? UI.fieldBorder : UI.danger.opacity(0.7))
                    )
                helpers
            }
            status(error)
            HStack {
                Button("Remove expression") {
                    doc.setExpr(slot, nil); close()
                }.buttonStyle(PillButtonStyle())
                Spacer()
                Button("Cancel", action: close).buttonStyle(PillButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Apply") {
                    doc.setExpr(slot, draft); close()
                }
                .buttonStyle(PillButtonStyle(primary: true)).keyboardShortcut(.return, modifiers: .command).disabled(
                    error != nil
                ).opacity(error != nil ? 0.4 : 1)
                .help(error != nil ? "Fix the error first" : "Apply (⌘↩)")
            }
        }
        .popoverChrome()
        .onAppear { draft = initial }
    }

    @ViewBuilder private func status(_ error: String?) -> some View {
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill").font(UI.mono).foregroundStyle(UI.danger)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } else {
            HStack(spacing: 6) {
                Text("At \(fmt((doc.time * 100).rounded() / 100)) s").font(UI.small).foregroundStyle(UI.dim)
                Text("= " + Self.valueText(doc, slot, draft)).font(UI.mono).foregroundStyle(UI.text).lineLimit(1)
            }
        }
    }

    private var helpers: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SmallCapsLabel("Insert").padding(.bottom, 2)
                HStack(spacing: 3) {
                    ForEach(Self.variables, id: \.insert) { h in chip(h, short: true) }
                }
                ForEach(Self.functions, id: \.insert) { h in chip(h, short: false) }
            }
        }
        .frame(width: 190, height: 180)
    }

    private func chip(_ h: Helper, short: Bool) -> some View {
        Button {
            editor.insert(h.insert)
        } label: {
            Text(short ? h.insert : String(h.insert.prefix(while: { $0 != "(" })) + "()")
                .font(UI.monoSmall).foregroundStyle(UI.text)
                .padding(.horizontal, 6).frame(height: 20)
                .background(RoundedRectangle(cornerRadius: 4).fill(UI.field))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(UI.fieldBorder))
        }
        .buttonStyle(.plain).cursor(.pointingHand).help(h.doc + "\n" + h.insert)
    }

    /// The expression's value at the playhead (for repeater copies: copy 0).
    static func valueText(_ doc: EditorDocument, _ slot: Slot, _ src: String) -> String {
        guard doc.exprError(src) == nil else { return "—" }
        let v = doc.renderer.evaluator.expr.eval(src, t: slot.local, T: doc.time, i: 0, d: doc.scene.duration, n: 1)
        let s: String
        if let d = v.double, case .number = v {
            s = fmt((d * 1000).rounded() / 1000)
        } else if v == .null {
            return "— (needs the full scene, e.g. repeater stats)"
        } else {
            s = v.compactString
        }
        return slot.isTop ? s : s + "  (copy 0)"
    }
}

/// Lets SwiftUI buttons insert text at the cursor of the NSTextView.
private final class CodeEditorController: ObservableObject {
    weak var textView: NSTextView?
    func insert(_ s: String) {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        tv.insertText(s, replacementRange: tv.selectedRange())
    }
}

/// Monospace plain-text editor (no smart quotes or substitutions).
private struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    let controller: CodeEditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        Self.applyTheme(tv)
        context.coordinator.observeTheme(tv)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = NSSize(width: 4, height: 6)
        tv.string = text
        tv.delegate = context.coordinator
        controller.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        Self.applyTheme(tv)
        controller.textView = tv
    }

    /// AppKit colours are fixed values: refreshed on every update and on app theme changes (not just at creation).
    static func applyTheme(_ tv: NSTextView) {
        let c = NSColor(UI.text)
        if tv.textColor != c { tv.textColor = c }
        if tv.insertionPointColor != c { tv.insertionPointColor = c }
        tv.typingAttributes[.foregroundColor] = c
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: CodeTextView
        private var themeToken: NSObjectProtocol?
        init(_ p: CodeTextView) { parent = p }
        deinit { if let t = themeToken { NotificationCenter.default.removeObserver(t) } }

        func observeTheme(_ tv: NSTextView) {
            themeToken = NotificationCenter.default.addObserver(forName: .appThemeChanged, object: nil, queue: .main) {
                [weak tv] _ in
                if let tv { CodeTextView.applyTheme(tv) }
            }
        }
        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
        }
    }
}
