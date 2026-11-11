import SwiftUI

/// What a commit-on-Return field shows. It follows the model value (scrubbing, sliders, canvas drags, undo, AI edits)
/// until the user actually types; only typed text is ever committed, and a field that merely has keyboard focus
/// (clicked, then the label was dragged) keeps tracking the value instead of freezing on what it showed at the click.
struct FieldDraft: Equatable {
    /// Text in the field.
    private(set) var text: String
    /// Model value the field last showed.
    private(set) var base: String

    init(_ value: String) { text = value; base = value }

    /// The user typed something different from the model value.
    var isDirty: Bool { text != base }

    /// Keystrokes.
    mutating func edit(_ s: String) { text = s }

    /// The model value changed. Typed text survives only while the field is focused (being typed in).
    mutating func sync(_ value: String, focused: Bool) {
        if !focused || !isDirty { text = value }
        base = value
    }

    /// Return / leaving the field: the text to commit (typed and different from `value`), or nil. Afterwards the
    /// field shows `value` again until the commit comes back as a new model value (rejected input is reverted).
    mutating func finish(_ value: String) -> String? {
        let out = isDirty && text != value ? text : nil
        text = value; base = value
        return out
    }
}

/// Text field that commits on Return or when it loses focus, and follows external changes unless the user is typing.
struct TextCommitField: View {
    let text: String
    var mono = false
    var multiline = false
    var placeholder = ""
    var emphasized = false
    let commit: (String) -> Void
    @State private var draft = FieldDraft("")
    @FocusState private var focused: Bool

    var body: some View {
        let binding = Binding(get: { draft.text }, set: { draft.edit($0) })
        FieldBox {
            Group {
                if multiline {
                    TextField(placeholder, text: binding, axis: .vertical).lineLimit(1...6)
                } else {
                    TextField(placeholder, text: binding)
                }
            }
            .font(mono ? UI.mono : UI.font)
            .foregroundStyle(emphasized ? UI.accent : UI.text)
            .focused($focused)
            .onSubmit {
                if let s = draft.finish(text) { commit(s) }
                DispatchQueue.main.async { endEditing() }  // Return leaves the field, so Space/⌘Z work again
            }
            .padding(.vertical, multiline ? 4 : 0)
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(focused ? UI.label2.opacity(0.6) : .clear, lineWidth: 1))
        .cursor(.iBeam)
        .onAppear { draft = FieldDraft(text) }
        .onChange(of: text) { _, t in draft.sync(t, focused: focused) }
        .onChange(of: focused) { _, f in if !f, let s = draft.finish(text) { commit(s) } }
    }
}

/// Number entry for layer in/out points.
struct MetaField: View {
    let label: String
    let value: Double?
    var unit: String? = nil
    let commit: (Double?) -> Void
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(UI.small).foregroundStyle(UI.label2).frame(width: UI.labelWidth, alignment: .leading)
            TextCommitField(text: value.map(fmt) ?? "", mono: true, placeholder: "—") { s in
                commit(Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")))
            }
            .frame(maxWidth: 120)
            if let unit { Text(unit).font(UI.monoSmall).foregroundStyle(UI.faint) }
            Spacer(minLength: 0)
        }
    }
}

/// Integer field with − / + buttons.
struct StepperField: View {
    let value: Int
    let min: Int?
    let max: Int?
    var emphasized = false
    let commit: (Int) -> Void

    var body: some View {
        HStack(spacing: 4) {
            TextCommitField(text: String(value), mono: true, emphasized: emphasized) { s in
                if let d = Double(s.trimmingCharacters(in: .whitespaces)) { commit(clamp(Int(d.rounded()))) }
            }
            stepButton("minus") { commit(clamp(value - 1)) }
            stepButton("plus") { commit(clamp(value + 1)) }
        }
    }

    private func clamp(_ v: Int) -> Int { Swift.min(max ?? .max, Swift.max(min ?? .min, v)) }

    private func stepButton(_ s: String, _ a: @escaping () -> Void) -> some View {
        Button(action: a) {
            Image(systemName: s).font(.system(size: 9, weight: .bold)).foregroundStyle(UI.label2)
                .frame(width: 22, height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(UI.field))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.fieldBorder, lineWidth: 1))
                .hitArea()
        }
        .buttonStyle(.plain).cursor(.pointingHand)
    }
}
