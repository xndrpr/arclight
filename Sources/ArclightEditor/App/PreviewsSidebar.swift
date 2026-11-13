import AppKit
import ArclightCore
import SwiftUI

/// Preview workspace, left sidebar: preview pages, each with its artboards (thumbnail, variants, covers).
struct PreviewsSidebar: View {
    @ObservedObject var doc: EditorDocument
    @State private var hover: String?
    @State private var renaming: String?
    @Namespace private var ns

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Previews", trailing: AnyView(NewPreviewMenu(doc: doc)))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(doc.previews, id: \.id) { p in page(p).transition(Motion.row) }
                }
                .padding(.horizontal, 6).padding(.bottom, 10)
                .animation(Motion.snappy, value: doc.target)
                .animation(Motion.snappy, value: doc.previews.map(\.id))
                if let p = doc.openPreview { ThemeLinkRow(doc: doc, preview: p).padding(.horizontal, 12) }
                if doc.previews.count == 1 && (doc.previews.first?.artboards.count ?? 0) == 1 {
                    Text(
                        "Add variants for A/B tests or a Shorts cover with + on the page. Ask the AI to make a thumbnail: it can create and edit previews too."
                    )
                    .font(UI.small).foregroundStyle(UI.faint).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.top, 10)
                }
            }
        }
        .background(UI.panel)
    }

    private func page(_ p: ArclightCore.Preview) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack").font(.system(size: 10.5)).foregroundStyle(UI.dim)
                if renaming == "page:" + p.id {
                    RenameField(initial: p.name ?? p.id, placeholder: "Preview name") { n in
                        renaming = nil
                        if let n, n != (p.name ?? p.id) { doc.renamePreview(p.id, n) }
                    }
                } else {
                    Text(p.name ?? p.id).font(.system(size: 12, weight: .semibold)).foregroundStyle(UI.label2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                AddArtboardMenu(doc: doc, preview: p.id)
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 3)
            .contentShape(Rectangle())
            .onClick { count in if count >= 2 { renaming = "page:" + p.id } }
            .contextMenu {
                Button("Rename") { renaming = "page:" + p.id }
                Button("Duplicate Page") { doc.duplicatePreview(p.id) }
                Divider()
                Button("Delete Page") { doc.deletePreview(p.id) }
            }
            ForEach(p.artboards, id: \.id) { a in row(p, a) }
        }
    }

    @ViewBuilder private func row(_ p: ArclightCore.Preview, _ a: Artboard) -> some View {
        let key = p.id + "/" + a.id
        let selected = doc.target == .artboard(preview: p.id, artboard: a.id)
        // The open artboard's thumbnail follows the working copy as you edit.
        let shown = selected ? doc.scene : a.asScene(preview: p.id, rev: p.rev)
        HStack(spacing: 8) {
            SceneThumb(doc: doc, scene: shown)
                .frame(width: 56, height: 56 * CGFloat(min(1.25, Double(a.height) / Double(max(a.width, 1)))))
                .opacity(selected ? 1 : 0.85)
            VStack(alignment: .leading, spacing: 2) {
                if renaming == key {
                    RenameField(initial: a.name ?? a.id, placeholder: "Artboard name") { n in
                        renaming = nil
                        if let n, n != (a.name ?? a.id) { doc.renameArtboard(a.id, in: p.id, n) }
                    }
                } else {
                    Text(a.name ?? a.id).font(UI.font).foregroundStyle(UI.text).lineLimit(1)
                }
                Text("\(String(a.width))×\(String(a.height)) · \(a.nodes.count) layers").font(UI.monoSmall).foregroundStyle(UI.dim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 6).fill(UI.selected).matchedGeometryEffect(id: "selected", in: ns)
            } else if hover == key {
                RoundedRectangle(cornerRadius: 6).fill(UI.hover)
            }
        }
        .hitArea()
        .onHover { h in hover = h ? key : nil }
        .cursor(.pointingHand)
        .onClick(enabled: renaming != key) { count in
            if count >= 2 { renaming = key } else if !selected { endEditing(); doc.open(preview: p.id, artboard: a.id) }
        }
        .help("Click to open · double-click to rename · right-click for more")
        .contextMenu {
            Button("Rename") { renaming = key }
            Button("Duplicate as Variant") { doc.duplicateArtboard(a.id, in: p.id) }
            Menu("Resize") {
                ForEach(ArtboardPresets.all, id: \.self) { pr in
                    Button(pr.title + (pr.size == a.size ? "  ✓" : "")) {
                        doc.applyPage(
                            p.id,
                            [["op": "artboard_set", "id": .string(a.id), "size": .array(pr.size.map { .number(Double($0)) })]],
                            summary: "resize \(a.id)")
                    }
                }
            }
            Divider()
            Button("Delete Artboard") { doc.deleteArtboard(a.id, in: p.id) }.disabled(p.artboards.count < 2)
        }
    }
}

/// "+" on a page: a new artboard from a size preset.
private struct AddArtboardMenu: View {
    @ObservedObject var doc: EditorDocument
    let preview: String
    var body: some View {
        Menu {
            Section("New artboard") {
                ForEach(ArtboardPresets.all, id: \.self) { p in
                    Button(p.title) { doc.addArtboard(preset: p, to: preview) }
                }
            }
        } label: {
            Image(systemName: "plus").font(.system(size: 10.5, weight: .medium)).foregroundStyle(UI.dim)
                .frame(width: 20, height: 18).hitArea()
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 20, height: 18)
        .help("Add an artboard (thumbnail, Shorts cover, square…)").cursor(.pointingHand)
    }
}

/// "+" in the Previews header.
private struct NewPreviewMenu: View {
    @ObservedObject var doc: EditorDocument
    var body: some View {
        Button { doc.newPreview() } label: {
            Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(UI.dim)
                .frame(width: 24, height: 22).hitArea()
        }
        .buttonStyle(.plain).help("New preview page (⇧⌘N)").cursor(.pointingHand)
    }
}

/// Whether the open page follows the project theme, with the switch to detach or re-link it.
private struct ThemeLinkRow: View {
    @ObservedObject var doc: EditorDocument
    let preview: ArclightCore.Preview
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: preview.theme.isDetached ? "link.badge.plus" : "link")
                .font(.system(size: 10.5)).foregroundStyle(UI.dim)
            Text(preview.theme.isDetached ? "Own theme" : "Project theme").font(UI.small).foregroundStyle(UI.label2)
            Spacer(minLength: 0)
            Button(preview.theme.isDetached ? "Link to project" : "Detach") {
                if preview.theme.isDetached { doc.relinkTheme() } else { doc.detachTheme() }
            }
            .buttonStyle(PillButtonStyle()).controlSize(.small)
            .help(
                preview.theme.isDetached
                    ? "Use the project theme again (this page's own colours and fonts are replaced)"
                    : "Give this page its own colours and fonts; project theme changes stop reaching it")
        }
        .padding(.vertical, 8)
    }
}
