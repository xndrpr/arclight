import AppKit
import ArclightCore
import SwiftUI

/// Inspector for one layer: header (+ Animate presets), Timing, Transform, the type's own sections, Custom props.
struct LayerInspector: View {
    @ObservedObject var doc: EditorDocument
    let node: Node
    @Environment(\.inspectorQuery) private var query

    var body: some View {
        let schema = Schema.node(node.type)
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(
                icon: schema?.icon ?? symbol(for: node.type), title: node.name ?? node.id,
                subtitle: schema?.label ?? node.type, doc: schema?.doc ?? ""
            ) {
                LayerActions(doc: doc, node: node)
            }
            Hairline()
            if query.isEmpty || "timing in out".contains(query) { TimingSection(doc: doc, node: node) }
            InspectorSection(doc: doc, title: "Transform", host: .node(node.id), fields: Schema.transform)
            ForEach(InspectorLayout.sections(for: node.type), id: \.0) { title, fields in
                section(title, fields.filter { InspectorLayout.relevant($0, node) })
            }
            CustomSection(doc: doc, node: node)
        }
    }

    @ViewBuilder private func section(_ title: String, _ fields: [Field]) -> some View {
        if fields.count == 1, let f = fields.first, case .object(let o) = f.kind {
            if f.matches(query) || title.lowercased().contains(query) {
                ObjectSection(
                    doc: doc, slot: doc.slot(.node(node.id), f.name, field: f), schema: o, asSection: true, title: title
                )
                Hairline()
            }
        } else if !fields.isEmpty {
            InspectorSection(doc: doc, title: title, host: .node(node.id), fields: fields)
        }
    }
}

private struct TimingSection: View {
    @ObservedObject var doc: EditorDocument
    let node: Node

    var body: some View {
        CollapsibleSection(title: "Timing", trailing: AnyView(setButtons)) {
            VStack(alignment: .leading, spacing: 4) {
                MetaField(label: "In", value: node.start, unit: "s") { v in
                    doc.apply([["op": "set", "id": .string(node.id), "in": v.map { .number($0) } ?? .null]])
                }
                MetaField(label: "Out", value: node.end, unit: "s") { v in
                    doc.apply([["op": "set", "id": .string(node.id), "out": v.map { .number($0) } ?? .null]])
                }
                Text("Seconds in the scene where the layer appears and disappears. Empty = whole scene.")
                    .font(UI.small).foregroundStyle(UI.faint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var setButtons: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "arrow.right.to.line", help: "Set in point to the playhead (I)") {
                doc.apply([
                    ["op": "set", "id": .string(node.id), "in": .number((doc.time * doc.fps).rounded() / doc.fps)]
                ])
            }
            IconButton(symbol: "arrow.left.to.line", help: "Set out point to the playhead (O)") {
                doc.apply([
                    ["op": "set", "id": .string(node.id), "out": .number((doc.time * doc.fps).rounded() / doc.fps)]
                ])
            }
        }
    }
}

/// Animate menu, clear animation, duplicate, delete.
private struct LayerActions: View {
    @ObservedObject var doc: EditorDocument
    let node: Node

    var body: some View {
        HStack(spacing: 0) {
            AnimateMenu(doc: doc, node: node)
            if node.props.values.contains(where: { $0.keyCount > 0 }) {
                IconButton(
                    symbol: "arrow.counterclockwise", help: "Clear all keyframes on this layer (keeps current values)"
                ) { doc.clearAllAnimation(node.id) }
            }
            IconButton(symbol: "plus.square.on.square", help: "Duplicate (⌘D)") { doc.duplicateSelection() }
            IconButton(symbol: "trash", help: "Delete (⌫)") { doc.deleteSelection() }
        }
    }
}

private struct AnimateMenu: View {
    @ObservedObject var doc: EditorDocument
    let node: Node

    var body: some View {
        Menu {
            ForEach(AnimationPreset.Group.allCases, id: \.self) { g in
                Section(g.rawValue) {
                    ForEach(AnimationPresets.all.filter { $0.group == g && $0.applies(node) }) { p in
                        Button(p.title + "  ·  " + fmt(p.duration) + " s") { apply(p) }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "wand.and.stars").font(.system(size: 10.5))
                Text("Animate").font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(UI.text)
            .padding(.horizontal, 8).frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(UI.raised))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(UI.border))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().cursor(.pointingHand)
        .help("Add a ready-made animation at the playhead (exits end at the out point)")
        .padding(.trailing, 4)
    }

    private func apply(_ p: AnimationPreset) {
        let at = AnimationPresets.startTime(p, node: node, sceneTime: doc.time, sceneDuration: doc.scene.duration)
        let props = p.make(node, at, doc.fps)
        guard !props.isEmpty else { return }
        doc.applyProps(node.id, props)
        doc.flash(
            "\(p.group.rawValue): \(p.title) at \(fmt((doc.sceneTime(.node(node.id), local: at) * 100).rounded() / 100)) s"
        )
    }
}

/// Props the schema doesn't know (custom data, `_`-prefixed, or typos), edited as JSON.
private struct CustomSection: View {
    @ObservedObject var doc: EditorDocument
    let node: Node
    @Environment(\.inspectorQuery) private var query

    var body: some View {
        let known = Set(Schema.fields(for: node.type).map(\.name))
        let custom = node.props.keys.filter {
            !known.contains($0) && (query.isEmpty || $0.lowercased().contains(query))
        }.sorted()
        if query.isEmpty || !custom.isEmpty {
            CollapsibleSection(
                title: "Custom",
                trailing: AnyView(IconButton(symbol: "plus", help: "Add a custom property") { promptCustomProp() }),
                forceOpen: !query.isEmpty
            ) {
                VStack(spacing: UI.rowSpacing) {
                    ForEach(custom, id: \.self) { k in row(k) }
                    if custom.isEmpty {
                        Text(
                            "Your own data on this layer (for expressions or tools). Start the name with _ so it isn't flagged as a typo."
                        )
                        .font(UI.small).foregroundStyle(UI.faint).frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func row(_ k: String) -> some View {
        HStack(spacing: 6) {
            Text(k).font(UI.mono).foregroundStyle(k.hasPrefix("_") ? UI.label2 : UI.warning).lineLimit(1).frame(
                width: UI.labelWidth, alignment: .leading
            )
            .help(
                k.hasPrefix("_")
                    ? "Custom data" : "Not a known property of \(node.type) — custom data should start with _")
            CodeField(title: k, text: node.props[k].map { prettyJSON($0.json) } ?? "", badge: "{ }") { str in
                guard let j = JSONValue.parse(str) ?? (str.isEmpty ? nil : .string(str)), let p = try? Prop(json: j)
                else { return "Not valid JSON" }
                doc.setRaw(node.id, k, p); return nil
            }
            IconButton(symbol: "minus", help: "Remove") { doc.setRaw(node.id, k, nil) }
        }
    }

    private func promptCustomProp() {
        let a = NSAlert()
        a.messageText = "Add property"
        a.informativeText = "Name and JSON value"
        let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 22)); name.placeholderString = "_name"
        let value = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22));
        value.placeholderString = "value, e.g. 1 or \"#fff\""
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54)); box.addSubview(name); box.addSubview(value)
        a.accessoryView = box
        a.addButton(withTitle: "Add"); a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn, !name.stringValue.isEmpty else { return }
        let v = JSONValue.parse(value.stringValue) ?? .string(value.stringValue)
        doc.setRaw(node.id, name.stringValue, try? Prop(json: v))
    }
}
