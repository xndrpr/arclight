import ArclightCore
import SwiftUI

/// Back to the scene page.
private struct BackButton: View {
    @ObservedObject var doc: EditorDocument
    var body: some View {
        IconButton(symbol: "chevron.left", help: "Back to scene") { doc.selection = nil }
    }
}

struct CameraInspector: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        let f = Schema.sceneFields.first { $0.name == "camera" }!
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(icon: "video", title: "Camera", subtitle: "Scene", doc: Schema.camera.doc) {
                HStack(spacing: 0) {
                    if doc.scene.camera != nil {
                        PresetMenu(
                            title: "Presets",
                            items: ScenePresets.cameras(doc.canvasSize).map { p in
                                (p.0, { doc.edit { s in s.camera = .value(p.1) } })
                            })
                        IconButton(symbol: "trash", help: "Remove camera (3D layers line up with the canvas again)") {
                            doc.edit { $0.camera = nil }
                        }
                    }
                    BackButton(doc: doc)
                }
            }
            Hairline()
            if doc.scene.camera == nil {
                EmptyPresets(
                    text:
                        "No camera yet. 3D layers (repeaters, lights, layers with 3D on) line up 1:1 with the canvas until you add one.",
                    presets: ScenePresets.cameras(doc.canvasSize).map { p in
                        (p.0, p.2, { doc.edit { $0.camera = .value(p.1) } })
                    })
            } else {
                ObjectSection(
                    doc: doc, slot: doc.slot(.scene, "camera", field: f), schema: Schema.camera, asSection: true,
                    title: "Camera")
                Hairline()
                Text(
                    "Keyframe the camera to move it: ◆ adds a key with every field at the playhead; edits on an animated camera set the key there."
                )
                .font(UI.small).foregroundStyle(UI.faint).padding(UI.inset).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct LookInspector: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        let post = Schema.sceneFields.first { $0.name == "post" }!
        let fog = Schema.sceneFields.first { $0.name == "fog" }!
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(icon: "camera.filters", title: "Look", subtitle: "Scene", doc: Schema.post.doc) {
                HStack(spacing: 0) {
                    if doc.scene.post != nil || doc.scene.fog != nil {
                        PresetMenu(title: "Presets", items: ScenePresets.looks.map { p in (p.name, { apply(p) }) })
                    }
                    BackButton(doc: doc)
                }
            }
            Hairline()
            if doc.scene.post == nil && doc.scene.fog == nil {
                EmptyPresets(
                    text: "No look yet. Pick a starting point — you can tweak every value afterwards.",
                    presets: ScenePresets.looks.map { p in (p.name, p.detail, { apply(p) }) })
            } else {
                ObjectSection(
                    doc: doc, slot: doc.slot(.scene, "post", field: post), schema: Schema.post, asSection: true,
                    title: "Grade & effects")
                Hairline()
                ObjectSection(
                    doc: doc, slot: doc.slot(.scene, "fog", field: fog), schema: Schema.fog, asSection: true,
                    title: "Fog")
                Hairline()
            }
        }
    }

    private func apply(_ p: ScenePresets.Look) {
        doc.edit { s in
            s.post = .value(p.post)
            s.fog = p.fog.map { .value($0) }
        }
        doc.flash("Look: \(p.name)")
    }
}
