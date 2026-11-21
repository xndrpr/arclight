import AppKit
import ArclightCore
import SwiftUI

/// A sound clip picked in the timeline's sounds lane, or the scene's own audio: its fields (file, time, volume,
/// fades, effects), edited like any other value.
struct SoundInspector: View {
    let doc: EditorDocument
    let id: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if id == EditorDocument.sceneAudioId {
                sceneAudio
            } else if let i = doc.scene.sounds?.firstIndex(where: { $0.id == id }), let list = Self.listField,
                case .list(let schema) = list.kind
            {
                clip(doc.scene.sounds![i], index: i, list: list, schema: schema)
            }
        }
    }

    private static let listField = Schema.sceneFields.first { $0.name == "sounds" }
    private static let audioField = Schema.sceneFields.first { $0.name == "audio" }

    private func clip(_ r: AudioRef, index i: Int, list: Field, schema: ObjectSchema) -> some View {
        let slot = doc.slot(.scene, "sounds", field: list)
        return Group {
            InspectorHeader(
                icon: "waveform", title: id, subtitle: "Sound",
                doc: "\((r.src as NSString).lastPathComponent) at \(fmt(r.offset ?? 0)) s. Drag it in the timeline to move it."
            ) {
                actions
            }
            Hairline()
            CollapsibleSection(title: "Sound") {
                FieldList(doc: doc, fields: schema.fields.filter { $0.name != "id" }) { f in
                    doc.child(slot, ["\(i)", f.name], f)
                }
            }
        }
    }

    @ViewBuilder private var sceneAudio: some View {
        if let f = Self.audioField, case .object(let schema) = f.kind, let a = doc.scene.audio {
            InspectorHeader(
                icon: "waveform.path", title: (a.src as NSString).lastPathComponent, subtitle: "Scene audio",
                doc: "The scene's music or voiceover, under the ruler. Sound clips mix over it."
            ) {
                actions
            }
            Hairline()
            ObjectSection(
                doc: doc, slot: doc.slot(.scene, "audio", field: f), schema: schema, asSection: true, title: "Audio")
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "trash", help: "Remove (⌫)") { doc.deleteSelection() }
            IconButton(symbol: "xmark", help: "Back to the scene") { doc.selectedSound = nil }
        }
    }
}
