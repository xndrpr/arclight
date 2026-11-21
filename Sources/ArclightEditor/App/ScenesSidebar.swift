import AppKit
import ArclightCore
import SwiftUI

struct ScenesSidebar: View {
    let doc: EditorDocument
    @State private var hover: String?
    @State private var renaming: String?
    @Namespace private var ns
    /// Drag to reorder: the scene being dragged, where the pointer is (in the list) and each row's frame.
    @State private var dragging: String?
    @State private var dragY: CGFloat = 0
    @State private var frames: [String: CGRect] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Scenes", trailing: AnyView(NewSceneMenu(doc: doc)))
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(doc.scenes, id: \.id) { s in
                        row(s).transition(Motion.row)
                            .background(GeometryReader { g in
                                Color.clear.preference(key: RowFrames.self, value: [s.id: g.frame(in: .named(Self.space))])
                            })
                            .opacity(dragging == s.id ? 0.45 : 1)
                    }
                }
                .overlay(alignment: .topLeading) { dropLine }
                .coordinateSpace(name: Self.space)
                .onPreferenceChange(RowFrames.self) { frames = $0 }
                .padding(.horizontal, 6)
                // The selection slides to the opened scene; added / removed scenes drop in and out.
                .animation(Motion.snappy, value: doc.scene.id)
                .animation(Motion.snappy, value: doc.scenes.map(\.id))
                if doc.scenes.count == 1 {
                    Text("A video can have several scenes. Add one with + (⇧⌘N); double-click a scene to rename it, drag it to change the order.")
                        .font(UI.small).foregroundStyle(UI.faint).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.top, 10)
                }
            }
        }
        .background(UI.panel)
    }

    @ViewBuilder private func row(_ s: Scene) -> some View {
        let selected = s.id == doc.scene.id
        Group {
            if renaming == s.id {
                HStack(spacing: 8) {
                    SceneThumb(doc: doc, scene: s)
                        .frame(width: 56, height: 56 * CGFloat(canvasRatio(s)))
                    VStack(alignment: .leading, spacing: 2) {
                        RenameField(initial: s.name ?? s.id, placeholder: "Scene name") { n in
                            renaming = nil
                            if let n, n != (s.name ?? s.id) { doc.renameScene(s.id, n) }
                        }
                        Text("\(fmt(s.duration))s · \(s.nodes.count) layers").font(UI.monoSmall)
                            .foregroundStyle(UI.dim).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            } else {
                // Equatable: a change elsewhere in the editor (selection, playhead, a panel) doesn't redo 30 rows.
                SceneRowLabel(
                    doc: doc, scene: s, rev: s.rev, name: s.name ?? s.id, duration: s.duration, layers: s.nodes.count,
                    ratio: canvasRatio(s), selected: selected
                )
                .equatable()
            }
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
        // Dragging a row up or down moves the scene (the click handler ignores presses that move).
        .simultaneousGesture(
            DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
                .onChanged { g in
                    guard renaming != s.id, doc.scenes.count > 1 else { return }
                    if dragging == nil { dragging = s.id }
                    dragY = g.location.y
                }
                .onEnded { _ in
                    guard let id = dragging else { return }
                    let to = dropIndex
                    dragging = nil
                    withMotion(Motion.snappy) { doc.moveScene(id, to: to) }
                }
        )
        .help("Click to open · double-click to rename · drag to reorder · right-click for more")
        .contextMenu {
            let i = doc.scenes.firstIndex { $0.id == s.id } ?? 0
            Button("Rename") { renaming = s.id }
            Button("Move Up") { withMotion(Motion.snappy) { doc.moveScene(s.id, to: i - 1) } }.disabled(i == 0)
            Button("Move Down") { withMotion(Motion.snappy) { doc.moveScene(s.id, to: i + 2) } }
                .disabled(i >= doc.scenes.count - 1)
            Button("Duplicate") { doc.duplicateScene(s.id) }
            Button("Save as Template…") { LibrarySheets.saveTemplate(doc, scene: s.id) }
            Divider()
            Button("Delete") { doc.deleteScene(s.id) }.disabled(doc.scenes.count < 2)
        }
    }

    private static let space = "scenes-list"

    /// Where the dragged scene would land: the gap before the first row whose middle is below the pointer.
    private var dropIndex: Int {
        let ids = doc.scenes.map(\.id)
        return ids.firstIndex { (frames[$0]?.midY ?? .infinity) > dragY } ?? ids.count
    }

    /// The accent line in the gap the dragged scene would drop into (none when it would stay put).
    @ViewBuilder private var dropLine: some View {
        if let id = dragging, let from = doc.scenes.firstIndex(where: { $0.id == id }) {
            let ids = doc.scenes.map(\.id), to = dropIndex
            if to != from, to != from + 1 {
                let y = to < ids.count ? (frames[ids[to]]?.minY ?? 0) - 1 : (frames[ids[ids.count - 1]]?.maxY ?? 0) + 1
                RoundedRectangle(cornerRadius: 1).fill(UI.accent).frame(height: 2)
                    .padding(.horizontal, 4).offset(y: y - 1).allowsHitTesting(false)
            }
        }
    }

    /// Height / width of a scene's canvas, clamped so vertical scenes don't make huge rows.
    private func canvasRatio(_ s: Scene) -> Double {
        let (w, h) = doc.project.size(for: s)
        return min(1, Double(h) / Double(max(w, 1)))
    }
}

private struct RowFrames: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// "+" in the scenes header: a blank scene or one from a template.
private struct NewSceneMenu: View {
    let doc: EditorDocument
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

/// One scene row's picture and text. Compared by value, so it is only drawn again when the scene itself changes.
private struct SceneRowLabel: View, Equatable {
    let doc: EditorDocument
    let scene: Scene
    let rev: Int
    let name: String
    let duration: Double
    let layers: Int
    let ratio: Double
    let selected: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.scene.id == b.scene.id && a.rev == b.rev && a.name == b.name && a.duration == b.duration
            && a.layers == b.layers && a.ratio == b.ratio && a.selected == b.selected
    }

    var body: some View {
        HStack(spacing: 8) {
            SceneThumb(doc: doc, scene: scene)
                .frame(width: 56, height: 56 * CGFloat(ratio))
                .opacity(selected ? 1 : 0.85)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(UI.font).foregroundStyle(UI.text).lineLimit(1)
                Text("\(fmt(duration))s · \(layers) layers").font(UI.monoSmall).foregroundStyle(UI.dim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}
