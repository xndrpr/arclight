import AppKit
import ArclightCore
import SwiftUI

extension NameRow {
    @ViewBuilder func menu(_ n: Node, hidden: Bool, locked: Bool, soloed: Bool, isGroup: Bool) -> some View {
        let ids = doc.targets(id)
        let many = ids.count > 1
        Button("Rename") { beginRename() }.disabled(many)
        Button("Duplicate") {
            doc.selection = id; doc.duplicateSelection()
        }
        Button("Copy") {
            doc.selection = id; doc.copySelection()
        }
        Divider()
        Button(many ? "Group \(ids.count) Layers" : "Group") { doc.groupSelection(ids) }
        if ids.contains(where: { doc.scene.node($0)?.type == "group" }) {
            Button("Ungroup") { doc.ungroupSelection(ids) }
        }
        Divider()
        Button("Bring Forward") { doc.reorderLayer(id, forward: true) }
        Button("Send Backward") { doc.reorderLayer(id, forward: false) }
        Divider()
        Button(locked ? "Unlock" : "Lock") { doc.setLocked(ids, !locked) }
        Button(soloed ? "Unsolo" : "Solo") { doc.toggleSolo(ids) }
        Button(hidden ? "Show" : "Hide") { doc.setHidden(ids, !hidden) }
        Menu("Label") {
            ForEach(LayerLabel.names, id: \.self) { name in
                Button {
                    doc.setLabel(ids, name)
                } label: {
                    Label(
                        name.capitalized,
                        systemImage: LayerLabel.name(n) == name ? "checkmark.circle.fill" : "circle.fill")
                }
            }
            Divider()
            Button("None") { doc.setLabel(ids, nil) }
        }
        Divider()
        Button("Clear Keyframes") { for i in ids { doc.clearAllAnimation(i) } }
        Button("Delete") { doc.deleteLayers(ids) }
    }
}
