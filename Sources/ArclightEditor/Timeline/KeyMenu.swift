import AppKit
import ArclightCore
import SwiftUI

/// Right-click menu on keyframes: easing (the common curves; the inspector's picker has every `Easing.names` entry),
/// copy, paste at the playhead, delete.
struct KeyMenu: View {
    @ObservedObject var doc: EditorDocument
    let keys: Set<KeyRef>
    private static let easings = [
        "linear", "hold", "outExpo", "outCubic", "inOutCubic", "inCubic", "outBack", "spring", "inOutSine", "outQuart",
    ]

    var body: some View {
        let ui = doc.timelineUI
        if !keys.isEmpty {
            let common = KeyEdit.commonEase(doc.scene, keys)
            Menu(keys.count == 1 ? "Easing" : "Easing (\(keys.count) keys)") {
                ForEach(Self.easings, id: \.self) { n in
                    Button {
                        ui.selectedKeys = keys; doc.setEase(keys, n)
                    } label: {
                        if common == n { Label(n, systemImage: "checkmark") } else { Text(n) }
                    }
                }
            }
            Divider()
            Button(keys.count == 1 ? "Copy Keyframe" : "Copy \(keys.count) Keyframes") { doc.copyKeys(keys) }
        }
        Button("Paste Keyframes at Playhead") { doc.pasteKeys() }.disabled(ui.clipboard == nil)
        if !keys.isEmpty {
            Divider()
            Button(keys.count == 1 ? "Delete Keyframe" : "Delete \(keys.count) Keyframes") {
                doc.edit { $0 = KeyEdit.delete($0, keys) }
                ui.selectedKeys.subtract(keys)
            }
        }
    }
}
