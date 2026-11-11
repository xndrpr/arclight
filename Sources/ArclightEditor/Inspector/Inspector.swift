import AppKit
import ArclightCore
import SwiftUI

/// Right-hand inspector. Everything is driven by the schema (`ArclightCore.Schema`): every field of the selection is
/// shown with a widget for its kind, defaults greyed until edited. Selection routing:
/// several layers → `MultiSelectionInspector`; a layer → `LayerInspector`; "@camera" / "@look" → scene camera / look
/// editors; nothing → `SceneInspector`.
/// Layout grid: `UI.inset` left/right, `UI.labelWidth` label column, `UI.rowHeight` controls (InspectorMetrics.swift).
struct InspectorView: View {
    @ObservedObject var doc: EditorDocument
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            InspectorSearch(query: $query)
            Hairline()
            ScrollView {
                content
                    .environment(\.inspectorQuery, query.trimmingCharacters(in: .whitespaces).lowercased())
                    .padding(.bottom, 24)
            }
        }
        .background(UI.panel)
    }

    @ViewBuilder private var content: some View {
        if doc.selectedLayerIds.count > 1 {
            MultiSelectionInspector(doc: doc)
        } else {
            switch doc.selection {
            case PropHost.cameraSelection?: CameraInspector(doc: doc)
            case PropHost.lookSelection?: LookInspector(doc: doc)
            case let id?:
                if let node = doc.scene.node(id) {
                    LayerInspector(doc: doc, node: node)
                } else {
                    SceneInspector(doc: doc)
                }
            case nil: SceneInspector(doc: doc)
            }
        }
    }
}

/// Filter box above the inspector; sits on the same grid as the rows below. Esc clears it.
private struct InspectorSearch: View {
    @Binding var query: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(UI.faint)
            TextField("Search properties", text: $query).textFieldStyle(.plain).font(UI.font).foregroundStyle(UI.text)
                .focused($focused)
                .onExitCommand {
                    query = ""; focused = false
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(UI.dim)
                        .frame(width: 20, height: 20).hitArea()
                }
                .buttonStyle(.plain).cursor(.pointingHand).help("Clear search (Esc)")
            }
        }
        .fieldChrome(border: focused ? UI.label2.opacity(0.6) : UI.fieldBorder)
        .onClick(enabled: !focused) { _ in focused = true }
        .cursor(.iBeam)
        .padding(.horizontal, UI.inset).padding(.vertical, 8)
    }
}

/// A titled, collapsible group of schema fields on one host (layer or scene). Hidden while searching if nothing matches.
struct InspectorSection: View {
    @ObservedObject var doc: EditorDocument
    let title: String
    let host: PropHost
    let fields: [Field]
    var trailing: AnyView? = nil
    @Environment(\.inspectorQuery) private var query

    var body: some View {
        let shown = fields.filter { $0.matches(query) || title.lowercased().contains(query) }
        if !shown.isEmpty {
            if title.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    list(shown).padding(.horizontal, UI.inset).padding(.bottom, 12)
                    Hairline()
                }
            } else {
                CollapsibleSection(title: title, trailing: trailing, forceOpen: !query.isEmpty) { list(shown) }
            }
        }
    }

    private func list(_ shown: [Field]) -> some View {
        FieldList(doc: doc, fields: shown, showAdvanced: !query.isEmpty) { f in doc.slot(host, f.name, field: f) }
    }
}

/// Header line used by every inspector page: icon · name · type, trailing actions, one-line description.
struct InspectorHeader<Trailing: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let doc: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(UI.dim).frame(width: 16)
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(UI.text).lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle).font(UI.small).foregroundStyle(UI.dim).lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                trailing.fixedSize()
            }
            .frame(height: UI.rowHeight)
            if !doc.isEmpty {
                Text(doc).font(UI.small).foregroundStyle(UI.faint).lineLimit(2).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true).help(doc)
                    .padding(.leading, 24)
            }
        }
        .padding(.leading, UI.inset).padding(.trailing, UI.inset).padding(.vertical, 8)
    }
}

/// Several layers selected: what is selected and what you can do with all of them.
private struct MultiSelectionInspector: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        let ids = doc.selectedLayerIds
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(
                icon: "square.stack.3d.up", title: "\(ids.count) layers", subtitle: "Selection",
                doc: "Click a layer to edit its properties. ⌘- or ⇧-click in the layer list changes the selection."
            ) {
                HStack(spacing: 0) {
                    IconButton(symbol: "plus.square.on.square", help: "Duplicate all (⌘D)") { doc.duplicateSelection() }
                    IconButton(symbol: "trash", help: "Delete all (⌫)") { doc.deleteSelection() }
                }
            }
            Hairline()
            SectionTitle(title: "Selected")
            VStack(spacing: 2) {
                ForEach(ids, id: \.self) { id in
                    if let n = doc.scene.node(id) { MultiRow(doc: doc, node: n, primary: id == doc.selection) }
                }
            }
            .padding(.horizontal, UI.inset - 6).padding(.bottom, 12)
        }
    }
}

private struct MultiRow: View {
    @ObservedObject var doc: EditorDocument
    let node: Node
    let primary: Bool
    @State private var hover = false

    var body: some View {
        Button {
            doc.multiSelection = []; doc.selection = node.id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: Schema.node(node.type)?.icon ?? symbol(for: node.type)).font(.system(size: 11))
                    .foregroundStyle(UI.dim).frame(width: 16)
                Text(node.name ?? node.id).font(UI.font).foregroundStyle(UI.text).lineLimit(1)
                Text(Schema.node(node.type)?.label ?? node.type).font(UI.small).foregroundStyle(UI.faint).lineLimit(1)
                Spacer(minLength: 4)
                if primary { Text("primary").font(UI.small).foregroundStyle(UI.faint) }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(
                    hover ? UI.dim : UI.faint)
            }
            .padding(.horizontal, 6).frame(height: UI.rowHeight)
            .background(RoundedRectangle(cornerRadius: 5).fill(hover ? UI.hover : .clear))
            .hitArea()
        }
        .buttonStyle(.plain).onHover { hover = $0 }.cursor(.pointingHand).help("Edit only this layer")
    }
}
