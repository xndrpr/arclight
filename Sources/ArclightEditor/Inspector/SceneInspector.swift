import ArclightCore
import SwiftUI

/// Nothing selected: scene fields (duration, background, size/fps overrides), links to Camera and Look, theme tokens.
struct SceneInspector: View {
    @ObservedObject var doc: EditorDocument
    @Environment(\.inspectorQuery) private var query

    private var fields: [Field] {
        let (w, h) = doc.project.size(for: Scene(id: "_"))
        return Schema.sceneFields.compactMap { f in
            switch f.name {
            case "camera", "fog", "post": return nil
            // Show the project's values greyed until the scene overrides them.
            case "size":
                return Field(
                    f.name, f.kind, f.doc, label: "Canvas size", default: [.number(Double(w)), .number(Double(h))],
                    animatable: false)
            case "fps":
                return Field(
                    f.name, f.kind, f.doc, label: "Frame rate", default: .number(doc.project.fps), animatable: false)
            default: return f
            }
        }
    }

    var body: some View {
        let s = doc.scene
        VStack(alignment: .leading, spacing: 0) {
            InspectorHeader(
                icon: "film", title: s.name ?? s.id, subtitle: "Scene",
                doc: "Nothing selected: scene settings, camera, look and theme."
            ) {
                Text("rev \(s.rev)").font(UI.monoSmall).foregroundStyle(UI.faint)
                    .help("Revision: goes up every time the scene is saved (by you or an AI agent)")
            }
            Hairline()
            if matches("theme colours colors fonts palette preset") {
                CollapsibleSection(title: "Theme", forceOpen: !query.isEmpty) { ThemeRow(doc: doc) }
            }
            let shown = fields.filter { $0.matches(query) }
            let nameShown = matches("scene name")
            if nameShown || !shown.isEmpty {
                CollapsibleSection(title: "Scene", forceOpen: !query.isEmpty) {
                    VStack(alignment: .leading, spacing: UI.rowSpacing) {
                        if nameShown {
                            HStack(spacing: 6) {
                                Text("Name").font(UI.small).foregroundStyle(UI.label2).frame(
                                    width: UI.labelWidth, alignment: .leading)
                                TextCommitField(text: s.name ?? "", placeholder: s.id) { v in doc.renameScene(s.id, v) }
                            }
                        }
                        FieldList(doc: doc, fields: shown, showAdvanced: !query.isEmpty) { f in
                            doc.slot(.scene, f.name, field: f)
                        }
                    }
                }
            }
            if matches("3d camera look grade post fog effects") {
                CollapsibleSection(title: "3D & Look", forceOpen: !query.isEmpty) {
                    VStack(spacing: UI.rowSpacing) {
                        NavRow(
                            icon: "video", title: "Camera",
                            detail: s.camera == nil
                                ? "none — 3D matches the canvas"
                                : (s.camera!.keyCount > 0 ? "animated · \(s.camera!.keyCount) keys" : "set")
                        ) {
                            doc.selection = PropHost.cameraSelection
                        }
                        NavRow(icon: "camera.filters", title: "Look", detail: lookSummary(s)) {
                            doc.selection = PropHost.lookSelection
                        }
                    }
                }
            }
            if matches("theme tokens colours colors fonts " + doc.project.theme.keys.joined(separator: " ")) {
                ThemeEditor(doc: doc)
            }
        }
    }

    /// Whether the search box is empty or any of the space-separated words starts with the query.
    private func matches(_ words: String) -> Bool {
        query.isEmpty || words.split(separator: " ").contains { $0.lowercased().hasPrefix(query) }
            || words.lowercased().contains(query)
    }

    private func lookSummary(_ s: Scene) -> String {
        var parts: [String] = []
        if s.post != nil { parts.append(s.post!.keyCount > 0 ? "grade (animated)" : "grade") }
        if s.fog != nil { parts.append("fog") }
        return parts.isEmpty ? "none" : parts.joined(separator: " · ")
    }
}

/// A row that opens another inspector page.
private struct NavRow: View {
    let icon: String
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        NavRowButton(action: action) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(UI.dim).frame(width: 16)
            Text(title).font(UI.font).foregroundStyle(UI.text)
            Text(detail).font(UI.small).foregroundStyle(UI.faint).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(UI.faint)
        }
    }
}
