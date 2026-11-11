import AppKit
import ArclightCore
import SwiftUI

/// "+ Layer": every kind of layer, placed for the current canvas (centred, sized relative to it).
/// New layers start at the playhead.
struct AddLayerMenu: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        let c = doc.canvasSize
        let cx = JSONValue.number((c.width / 2).rounded()), cy = JSONValue.number((c.height / 2).rounded())
        let m = Double(min(c.width, c.height))
        let pad = JSONValue.number((m / 9).rounded())
        Menu {
            Button("Text") {
                doc.addNode(
                    "text",
                    props: [
                        "text": "Text", "font": "$display", "size": .number((m / 9).rounded()), "color": "$fg",
                        "x": pad, "y": pad,
                        "reveal": [
                            "by": "char", "stagger": 0.04, "duration": 0.6, "from": ["opacity": 0, "y": 50],
                            "mask": true,
                        ],
                    ])
            }
            Button("Counter") {
                doc.addNode(
                    "text",
                    props: [
                        "text": "{v}%", "font": "$display", "size": .number((m / 4).rounded()), "color": "$fg",
                        "x": pad, "y": pad,
                        "tabular": true, "value": ["k": [[0, 0], [1.5, 45, "outExpo"]]],
                    ])
            }
            Divider()
            Button("Rectangle") {
                doc.addNode(
                    "shape",
                    props: [
                        "shape": "rect", "x": cx, "y": cy, "width": .number((m * 0.37).rounded()),
                        "height": .number((m * 0.22).rounded()), "fill": "$fg",
                    ])
            }
            Button("Ellipse") {
                doc.addNode(
                    "shape",
                    props: [
                        "shape": "ellipse", "x": cx, "y": cy, "width": .number((m * 0.22).rounded()),
                        "height": .number((m * 0.22).rounded()), "fill": "$fg",
                    ])
            }
            Button("Line") {
                doc.addNode(
                    "shape",
                    props: [
                        "shape": "line", "x": .number((c.width / 2 - m * 0.18).rounded()), "y": cy,
                        "to": [.number((m * 0.37).rounded()), 0],
                        "strokeWidth": 3, "stroke": "$fg",
                        "trim": ["k": [[0, [0, 0]], [0.8, [0, 1], "inOutCubic"]]],
                    ])
            }
            SymbolsMenu(doc: doc)
            Button("Image…") { addImage() }
            Button("Group") { doc.addNode("group", props: ["x": 0, "y": 0]) }
            Divider()
            Button("Repeater (3D crowd)") { doc.addRepeater(symbol: "basic/person") }
            Button("Light (3D)") {
                doc.addNode(
                    "light",
                    props: [
                        "x": 960, "y": 830, "z": 1500,
                        "pool": ["radius": 600, "intensity": 0.2, "softness": 1, "falloff": 2],
                    ])
            }
            Divider()
            Button(doc.scene.audio == nil ? "Audio…" : "Replace Audio…") { doc.importAudio() }
            Button("From Template…") { LibrarySheets.templates(doc, mode: .insert) }
        } label: {
            Label("Layer", systemImage: "plus").font(UI.small).hitArea()
        }
        .menuStyle(.borderlessButton).fixedSize().foregroundStyle(UI.text).cursor(.pointingHand)
        .help("Add a layer at the playhead: text, shapes, a symbol, an image, a 3D crowd, audio or a template")
    }

    private func addImage() {
        guard let u = FilePicker.files([.image]).first, let name = try? doc.store.importAsset(from: u) else { return }
        doc.addImageLayer(name)
    }
}
