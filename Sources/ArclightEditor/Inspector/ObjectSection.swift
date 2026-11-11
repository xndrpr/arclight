import ArclightCore
import SwiftUI

/// Fields of one object (e.g. `reveal`, `pool`, the scene camera). Collapsible; `canDisable` objects get an on/off
/// switch; a keyframed top-level object gets ‹ ◆ › controls in the header. `asSection` draws it as a full
/// inspector section (uppercase header, no indent) instead of a nested sub-section.
struct ObjectSection: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot
    let schema: ObjectSchema
    var shorthand = false
    var asSection = false
    var title: String? = nil
    @State private var open: Bool?
    @Environment(\.inspectorQuery) private var query
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.inspectorIndent) private var indent

    private var isOn: Bool { slot.stored?.object != nil }
    private var expanded: Bool {
        !query.isEmpty || (open ?? (isOn && (asSection || !slot.field.canDisable || slot.isTop)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: asSection ? 0 : 6) {
            header
            if expanded && (isOn || !slot.field.canDisable) {
                ObjectFields(doc: doc, slot: slot, schema: schema, query: fieldQuery)
                    .padding(.leading, asSection ? 0 : UI.nestIndent)
                    .environment(\.inspectorIndent, indent + (asSection ? 0 : UI.nestIndent))
                    .overlay(alignment: .leading) { if !asSection { Rectangle().fill(UI.border).frame(width: 1) } }
                    .padding(.horizontal, asSection ? UI.inset : 0).padding(.bottom, asSection ? 12 : 2)
                    .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .clipped()
    }

    private func toggle() {
        withAnimation(reduceMotion ? nil : UI.snappy) { open = !expanded }
    }

    /// When the object itself matches the search, show all of its fields.
    private var fieldQuery: String {
        let q = query
        if q.isEmpty { return q }
        let f = slot.field
        return f.name.lowercased().contains(q) || f.label.lowercased().contains(q) || f.doc.lowercased().contains(q)
            ? "" : q
    }

    /// Sections: TITLE ˅ (like every inspector section). Nested objects: › Label.
    private var header: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                HStack(spacing: 5) {
                    if !asSection {
                        Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .bold)).foregroundStyle(
                            UI.faint
                        )
                        .rotationEffect(.degrees(expanded ? 90 : 0)).frame(width: 10)
                    }
                    titleText
                    if asSection && (isOn || !slot.field.canDisable) {
                        Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(
                            UI.faint
                        )
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                    }
                    if slot.rootAnimated && slot.isTop {
                        Circle().fill(UI.accent.opacity(0.8)).frame(width: 4, height: 4)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity).hitArea()
            }
            .buttonStyle(.plain).cursor(.pointingHand).help(slot.field.doc)
            headerControls
        }
        .padding(.leading, asSection ? UI.inset : 0).padding(.trailing, asSection ? UI.inset : 0)
        .frame(height: asSection ? UI.headerHeight : 24)
    }

    @ViewBuilder private var titleText: some View {
        let t = title ?? slot.field.label
        if asSection {
            SmallCapsLabel(t)
        } else {
            Text(t).font(.system(size: 11.5, weight: .medium)).foregroundStyle(isOn ? UI.text : UI.dim)
        }
    }

    @ViewBuilder private var headerControls: some View {
        if shorthand, let first = schema.fields.first {
            Button {
                doc.write(slot, slot.stored?[first.name] ?? first.defaultValue ?? 0)
            } label: {
                Text("Simple").font(UI.small).foregroundStyle(UI.dim).padding(.horizontal, 4).frame(height: 22)
                    .hitArea()
            }
            .buttonStyle(.plain).cursor(.pointingHand)
            .help("Use a single number (\(first.label.lowercased())) instead")
        }
        if slot.isTop && slot.field.animatable && isOn {
            KeyControls(doc: doc, slot: slot)
        }
        if slot.field.canDisable {
            SwitchField(value: isOn) { on in
                doc.write(slot, on ? .object([:]) : nil)
                open = on
            }
            .help(isOn ? "Turn off (removes \(slot.field.name))" : "Turn on")
        } else if !isOn {
            IconButton(symbol: "plus", help: "Add \(slot.field.label.lowercased())") {
                doc.write(slot, .object([:])); open = true
            }
        }
        if isOn {
            ObjectMenu(doc: doc, slot: slot)
        }
    }
}

/// "…" for an object: edit as JSON, reset, easing for the key at the playhead.
private struct ObjectMenu: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot
    @State private var editing = false

    var body: some View {
        Menu {
            keyEasingMenu(doc, slot)
            if slot.isTop && slot.rootAnimated {
                Button("Remove animation (keep current values)") { doc.clearAnimation(in: slot.host, slot.root) }
            }
            Button("Edit as JSON…") { editing = true }
            Button("Reset all fields") { doc.write(slot, .object([:])) }
            Button("Remove \(slot.field.label.lowercased())") { doc.write(slot, nil) }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(UI.dim).frame(width: 18, height: 22)
                .hitArea()
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18).cursor(.pointingHand).help(
            "More: edit as JSON, reset, remove"
        )
        .popover(isPresented: $editing, arrowEdge: .leading) {
            JSONPopover(title: slot.field.label, text: slot.stored.map(prettyJSON) ?? "{}") { str in
                guard let j = JSONValue.parse(str) else { return "Not valid JSON" }
                doc.write(slot, j); editing = false; return nil
            } cancel: {
                editing = false
            }
        }
    }
}

/// Monospace JSON editor body used by popovers.
struct JSONPopover: View {
    let title: String
    let text: String
    let apply: (String) -> String?
    let cancel: () -> Void
    @State private var draft = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(UI.text)
            TextEditor(text: $draft)
                .font(.system(size: 12, design: .monospaced)).scrollContentBackground(.hidden).padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(UI.field))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.fieldBorder))
                .frame(width: 420, height: 240)
            if let error { Text(error).font(UI.small).foregroundStyle(UI.danger) }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(PillButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Apply") { error = apply(draft) }.buttonStyle(PillButtonStyle(primary: true)).keyboardShortcut(
                    .return, modifiers: .command)
            }
        }
        .popoverChrome()
        .onAppear { draft = text }
    }
}

/// The rows of an object's fields, with advanced ones behind "More".
private struct ObjectFields: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot
    let schema: ObjectSchema
    let query: String

    var body: some View {
        FieldList(doc: doc, fields: schema.fields.filter { $0.matches(query) }, showAdvanced: !query.isEmpty) { f in
            doc.child(slot, f)
        }
    }
}

/// A list of field rows; advanced fields are hidden behind a "More" toggle (unless set or searching).
struct FieldList: View {
    @ObservedObject var doc: EditorDocument
    let fields: [Field]
    var showAdvanced = false
    let slotFor: (Field) -> Slot
    @State private var more = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.inspectorIndent) private var indent

    var body: some View {
        let slots = fields.map(slotFor)
        let basic = slots.filter { !$0.field.advanced || $0.isSet || showAdvanced }
        let advanced = slots.filter { $0.field.advanced && !$0.isSet && !showAdvanced }
        VStack(alignment: .leading, spacing: UI.rowSpacing) {
            ForEach(basic, id: \.id) { s in FieldRow(doc: doc, slot: s) }
            if !advanced.isEmpty {
                MoreToggle(
                    open: Binding(
                        get: { more }, set: { v in withAnimation(reduceMotion ? nil : UI.snappy) { more = v } }),
                    count: advanced.count, names: advanced.map(\.field.label))
                if more {
                    ForEach(advanced, id: \.id) { s in FieldRow(doc: doc, slot: s) }
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
        }
    }
}

private struct MoreToggle: View {
    @Binding var open: Bool
    let count: Int
    let names: [String]
    var body: some View {
        Button {
            open.toggle()
        } label: {
            HStack(spacing: 4) {
                Text(open ? "Fewer options" : "More options").font(UI.small).foregroundStyle(UI.dim)
                if !open { Text("\(count)").font(UI.monoSmall).foregroundStyle(UI.faint) }
                Image(systemName: "chevron.down").font(.system(size: 7.5, weight: .bold)).foregroundStyle(UI.faint)
                    .rotationEffect(.degrees(open ? 180 : 0))
                Spacer()
            }
            .frame(height: 20).hitArea()
        }
        .buttonStyle(.plain).cursor(.pointingHand).help(names.joined(separator: ", "))
    }
}
