import AppKit
import ArclightCore
import SwiftUI

struct ScenesSidebar: View {
    @ObservedObject var doc: EditorDocument
    @State private var hover: String?
    @State private var renaming: String?
    @Namespace private var ns

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Scenes", trailing: AnyView(NewSceneMenu(doc: doc)))
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(doc.scenes, id: \.id) { s in row(s).transition(Motion.row) }
                }
                .padding(.horizontal, 6)
                // The selection slides to the opened scene; added / removed scenes drop in and out.
                .animation(Motion.snappy, value: doc.scene.id)
                .animation(Motion.snappy, value: doc.scenes.map(\.id))
                if doc.scenes.count == 1 {
                    Text("A video can have several scenes. Add one with + (⇧⌘N); double-click a scene to rename it.")
                        .font(UI.small).foregroundStyle(UI.faint).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.top, 10)
                }
            }
        }
        .background(UI.panel)
    }

    @ViewBuilder private func row(_ s: Scene) -> some View {
        let selected = s.id == doc.scene.id
        HStack(spacing: 8) {
            SceneThumb(doc: doc, scene: s)
                .frame(width: 56, height: 56 * CGFloat(canvasRatio(s)))
                .opacity(selected ? 1 : 0.85)
            VStack(alignment: .leading, spacing: 2) {
                if renaming == s.id {
                    RenameField(initial: s.name ?? s.id, placeholder: "Scene name") { n in
                        renaming = nil
                        if let n, n != (s.name ?? s.id) { doc.renameScene(s.id, n) }
                    }
                } else {
                    Text(s.name ?? s.id).font(UI.font).foregroundStyle(UI.text).lineLimit(1)
                }
                Text("\(fmt(s.duration))s · \(s.nodes.count) layers").font(UI.monoSmall).foregroundStyle(UI.dim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 6).fill(UI.selected).matchedGeometryEffect(id: "selected", in: ns)
            } else if hover == s.id {
                RoundedRectangle(cornerRadius: 6).fill(UI.hover)
            }
        }
        .hitArea()
        .onHover { h in hover = h ? s.id : nil }
        .cursor(.pointingHand)
        // Single click opens right away; a double click (which starts with a single) then renames.
        // (Jitter-tolerant: SwiftUI's tap gestures dropped trackpad taps made while the finger was still moving.)
        .onClick(enabled: renaming != s.id) { count in
            if count >= 2 { renaming = s.id } else if s.id != doc.scene.id { endEditing(); doc.open(scene: s.id) }
        }
        .help("Click to open · double-click to rename · right-click for more")
        .contextMenu {
            Button("Rename") { renaming = s.id }
            Button("Duplicate") { doc.duplicateScene(s.id) }
            Button("Save as Template…") { LibrarySheets.saveTemplate(doc, scene: s.id) }
            Divider()
            Button("Delete") { doc.deleteScene(s.id) }.disabled(doc.scenes.count < 2)
        }
    }

    /// Height / width of a scene's canvas, clamped so vertical scenes don't make huge rows.
    private func canvasRatio(_ s: Scene) -> Double {
        let (w, h) = doc.project.size(for: s)
        return min(1, Double(h) / Double(max(w, 1)))
    }
}

/// "+" in the scenes header: a blank scene or one from a template.
private struct NewSceneMenu: View {
    @ObservedObject var doc: EditorDocument
    var body: some View {
        Menu {
            Button("New Scene") { doc.newScene() }
            Button("New Scene from Template…") { LibrarySheets.templates(doc, mode: .newScene) }
        } label: {
            Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(UI.dim)
                .frame(width: 24, height: 22).hitArea()
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 24, height: 22)
        .help("New scene (⇧⌘N) or from a template (⌥⌘N)").cursor(.pointingHand)
    }
}
