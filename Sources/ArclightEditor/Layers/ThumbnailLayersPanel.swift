import ArclightCore
import SwiftUI

/// Thumbnail workspace: the open artboard's layers (Figma's layer list), top-most first. The same rows as the
/// timeline's name column — select, rename, reorder, group, lock, hide — without tracks or camera/look rows.
struct ThumbnailLayersPanel: View {
    let doc: EditorDocument
    @AppStorage(Pref.layerDensity) private var density = LayerDensity.detailed.rawValue

    var body: some View {
        let ui = doc.layerUI
        let rows = LayerTree.rows(
            doc.scene, selection: doc.selection, collapsed: ui.collapsed(doc.scene.id), filter: ui.filter,
            pinned: false
        ).filter { $0.prop == nil }  // no keyframe sub-rows: artboards are stills
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SmallCapsLabel("Layers")
                Spacer(minLength: 0)
                AddLayerMenu(doc: doc)
            }
            .padding(.horizontal, 12).frame(height: 30)
            LayerListHeader(doc: doc).frame(height: 28)
            Hairline()
            ScrollView(.vertical) {
                NamesColumn(doc: doc, rows: rows).frame(maxWidth: .infinity, alignment: .top)
                if rows.isEmpty {
                    Text(
                        "No layers yet. Pick a tool on the left of the canvas (T text, R rectangle), drop an image, or ask the AI."
                    )
                    .font(UI.small).foregroundStyle(UI.faint).fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                }
            }
            .scrollIndicators(.never)
        }
        .background(UI.panel)
    }
}
