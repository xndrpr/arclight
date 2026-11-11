import AppKit
import ArclightCore
import SwiftUI

/// Left column of the timeline: one row per timeline row (same order, same `TL.rowH`).
/// Rows are pressed, clicked and dragged with one custom gesture (`NameRow.rowGesture`): click selects (also with
/// trackpad tap-to-click), drag reorders / re-parents with a drop line, double-click renames.
struct NamesColumn: View {
    @ObservedObject var doc: EditorDocument
    let rows: [TLRow]
    @AppStorage(Pref.layerDensity) private var density = LayerDensity.detailed.rawValue
    static let space = "layerNames"

    var body: some View {
        let ui = doc.layerUI
        let kids = LayerTree.children(doc.scene)
        let order = LayerTree.visualOrder(rows)
        let collapsed = ui.collapsed(doc.scene.id)
        if !doc.playing { ui.thumbTime = doc.viewTime }  // thumbnails stay put while playing
        let scene = doc.scene
        let dropAt: (CGFloat) -> LayerTree.Drop? = { y in
            LayerTree.dropZone(scene, rows: rows, y: y, rowH: TL.rowH, collapsed: collapsed, dragging: ui.dragging)
        }
        return VStack(spacing: 0) {
            ForEach(rows) { r in
                NameRow(
                    doc: doc, ui: ui, row: r, childCount: kids[r.node.id]?.count ?? 0,
                    collapsed: collapsed.contains(r.node.id), order: order, thumbTime: ui.thumbTime,
                    detailed: density != LayerDensity.compact.rawValue, dropAt: dropAt
                )
                .transition(.opacity)
            }
        }
        .coordinateSpace(name: Self.space)
        .animation(doc.playing ? nil : Motion.animation(UI.fade), value: rows.map(\.id))
        .onChange(of: doc.selection) { _, s in if s == nil, !doc.multiSelection.isEmpty { doc.multiSelection = [] } }
    }
}

/// Filter field, layer count / solo indicator, density toggle. Sits in the ruler row above the names.
struct LayerListHeader: View {
    @ObservedObject var doc: EditorDocument
    @AppStorage(Pref.layerDensity) private var density = LayerDensity.detailed.rawValue
    @FocusState private var focused: Bool

    var body: some View {
        let ui = doc.layerUI
        let filter = Binding(get: { ui.filter }, set: { ui.filter = $0 })
        let total = doc.scene.nodes.count
        let shown = ui.filter.isEmpty ? total : doc.scene.nodes.filter { LayerTree.matches($0, ui.filter) }.count
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").font(.system(size: 10, weight: .medium)).foregroundStyle(
                focused ? UI.text : UI.faint)
            TextField("Filter layers", text: filter)
                .textFieldStyle(.plain).font(UI.small).foregroundStyle(UI.text).focused($focused)
                .onExitCommand {
                    ui.filter = ""; focused = false
                }
            if !ui.filter.isEmpty {
                Button {
                    ui.filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(UI.dim).frame(
                        width: 16, height: 18
                    ).hitArea()
                }
                .buttonStyle(.plain).help("Clear filter").cursor(.pointingHand)
            }
            if !doc.soloIds.isEmpty {
                Button {
                    doc.soloIds = []
                } label: {
                    HStack(spacing: 3) {
                        Text("SOLO \(doc.soloIds.count)").font(.system(size: 9, weight: .bold)).tracking(0.4)
                        Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                    }
                    .foregroundStyle(UI.onAccent).padding(.horizontal, 6).frame(height: 16)
                    .background(Capsule().fill(UI.accent)).hitArea()
                }
                .buttonStyle(.plain).help("Solo is on — only solo'd layers show in the viewer. Click to show all.")
                .cursor(.pointingHand)
            } else {
                Text(ui.filter.isEmpty ? "\(total)" : "\(shown)/\(total)").font(UI.monoSmall).foregroundStyle(UI.faint)
                    .help("\(total) layer\(total == 1 ? "" : "s")")
            }
            let detailed = density != LayerDensity.compact.rawValue
            IconButton(
                symbol: detailed ? "rectangle.grid.1x2" : "list.bullet",
                help: detailed ? "Detailed rows — switch to compact" : "Compact rows — switch to detailed"
            ) {
                doc.objectWillChange.send()
                density = (detailed ? LayerDensity.compact : .detailed).rawValue
            }
        }
        .padding(.leading, 10).padding(.trailing, 4)
        .frame(width: TL.nameW, height: TL.rulerH)
    }
}
