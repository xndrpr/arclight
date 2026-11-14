import AppKit
import ArclightCore
import SwiftUI

/// Thumbnail workspace, left sidebar: thumbnail pages, each with its artboards (thumbnail, variants, covers).
struct ThumbnailsSidebar: View {
    @ObservedObject var doc: EditorDocument
    @State private var hover: String?
    @State private var renaming: String?
    @Namespace private var ns

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Thumbnails", trailing: AnyView(NewThumbnailMenu(doc: doc)))
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(doc.thumbnails, id: \.id) { p in page(p).transition(Motion.row) }
                }
                .padding(.horizontal, 6).padding(.bottom, 10)
                .animation(Motion.snappy, value: doc.target)
                .animation(Motion.snappy, value: doc.thumbnails.map(\.id))
                if let p = doc.openThumbnail {
                    ThemeLinkRow(doc: doc, thumbnail: p).padding(.horizontal, 12)
                    ReferencesSection(doc: doc, thumbnail: p).padding(.horizontal, 12)
                }
                if doc.thumbnails.count == 1 && (doc.thumbnails.first?.artboards.count ?? 0) == 1 {
                    Text(
                        "Add variants for A/B tests or a Shorts cover with + on the page. Ask the AI to make a thumbnail: it can create and edit thumbnails too."
                    )
                    .font(UI.small).foregroundStyle(UI.faint).fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.top, 10)
                }
            }
        }
        .background(UI.panel)
    }

    private func page(_ p: ArclightCore.Thumbnail) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: "rectangle.stack").font(.system(size: 10.5)).foregroundStyle(UI.dim)
                if renaming == "page:" + p.id {
                    RenameField(initial: p.name ?? p.id, placeholder: "Thumbnail name") { n in
                        renaming = nil
                        if let n, n != (p.name ?? p.id) { doc.renameThumbnail(p.id, n) }
                    }
                } else {
                    Text(p.name ?? p.id).font(.system(size: 12, weight: .semibold)).foregroundStyle(UI.label2)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                AddArtboardMenu(doc: doc, thumbnail: p.id)
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 3)
            .contentShape(Rectangle())
            .onClick { count in if count >= 2 { renaming = "page:" + p.id } }
            .contextMenu {
                Button("Rename") { renaming = "page:" + p.id }
                Button("Duplicate Page") { doc.duplicateThumbnail(p.id) }
                Divider()
                Button("Delete Page") { doc.deleteThumbnail(p.id) }
            }
            ForEach(p.artboards, id: \.id) { a in row(p, a) }
        }
    }

    @ViewBuilder private func row(_ p: ArclightCore.Thumbnail, _ a: Artboard) -> some View {
        let key = p.id + "/" + a.id
        let selected = doc.target == .artboard(thumbnail: p.id, artboard: a.id)
        // The open artboard's thumbnail follows the working copy as you edit.
        let shown = selected ? doc.scene : a.asScene(thumbnail: p.id, rev: p.rev)
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
            if count >= 2 { renaming = key } else if !selected { endEditing(); doc.open(thumbnail: p.id, artboard: a.id) }
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
    let thumbnail: String
    var body: some View {
        Menu {
            Section("New artboard") {
                ForEach(ArtboardPresets.all, id: \.self) { p in
                    Button(p.title) { doc.addArtboard(preset: p, to: thumbnail) }
                }
                Button("From Template…") {
                    if doc.target.thumbnailId != thumbnail { doc.open(thumbnail: thumbnail) }
                    LibrarySheets.templates(doc, mode: .newArtboard)
                }
            }
            if doc.target.thumbnailId == thumbnail {
                Section("A/B variants of the open artboard") {
                    Button("2 colour variants") { doc.makeVariants(.color) }
                    Button("2 zoom variants") { doc.makeVariants(.zoom) }
                    Button("2 background variants") { doc.makeVariants(.background) }
                }
                Section("Background picture") {
                    Button("Best Frame from a Video…") { doc.frameFromVideo() }
                    if !doc.store.orderedScenes.isEmpty {
                        Menu("Snapshot of a Motion Scene") {
                            ForEach(doc.store.orderedScenes, id: \.id) { sc in
                                Button(sc.name ?? sc.id) { doc.snapshotScene(sc.id) }
                            }
                        }
                    }
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

/// "+" in the Thumbnails header.
private struct NewThumbnailMenu: View {
    @ObservedObject var doc: EditorDocument
    var body: some View {
        Menu {
            Button("New Thumbnail Page") { doc.newThumbnail() }
            Button("New from Template…") { LibrarySheets.templates(doc, mode: .newArtboard) }
        } label: {
            Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundStyle(UI.dim)
                .frame(width: 24, height: 22).hitArea()
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().frame(width: 24, height: 22)
        .help("New thumbnail page (⇧⌘N) or one from a thumbnail template").cursor(.pointingHand)
    }
}

/// Whether the open page follows the project theme, with the switch to detach or re-link it.
private struct ThemeLinkRow: View {
    @ObservedObject var doc: EditorDocument
    let thumbnail: ArclightCore.Thumbnail
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: thumbnail.theme.isDetached ? "link.badge.plus" : "link")
                .font(.system(size: 10.5)).foregroundStyle(UI.dim)
            Text(thumbnail.theme.isDetached ? "Own theme" : "Project theme").font(UI.small).foregroundStyle(UI.label2)
            Spacer(minLength: 0)
            Button(thumbnail.theme.isDetached ? "Link to project" : "Detach") {
                if thumbnail.theme.isDetached { doc.relinkTheme() } else { doc.detachTheme() }
            }
            .buttonStyle(PillButtonStyle()).controlSize(.small)
            .help(
                thumbnail.theme.isDetached
                    ? "Use the project theme again (this page's own colours and fonts are replaced)"
                    : "Give this page its own colours and fonts; project theme changes stop reaching it")
        }
        .padding(.vertical, 8)
    }
}

/// Reference thumbnails kept with the page (never exported): add a picture or a YouTube link, analyse, remove.
private struct ReferencesSection: View {
    @ObservedObject var doc: EditorDocument
    let thumbnail: ArclightCore.Thumbnail
    @State private var link = ""
    @State private var analyzing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SmallCapsLabel("References")
                Spacer()
                Button {
                    if let u = FilePicker.files([.image]).first { doc.addReference(u.path) }
                } label: { Image(systemName: "plus").font(.system(size: 10.5, weight: .medium)).foregroundStyle(UI.dim) }
                    .buttonStyle(.plain).help("Add a reference picture").cursor(.pointingHand)
            }
            TextField("Paste a YouTube link…", text: $link).textFieldStyle(.roundedBorder).font(UI.small)
                .onSubmit { if !link.isEmpty { doc.addReference(link); link = "" } }
            let refs = thumbnail.references ?? []
            if refs.isEmpty {
                Text("Thumbnails you like, to study their layout and colours (the AI can too). Never exported.")
                    .font(UI.small).foregroundStyle(UI.faint).fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 6)], spacing: 6) {
                ForEach(refs, id: \.self) { r in
                    ReferenceThumb(url: doc.assets.appendingPathComponent(r))
                        .onTapGesture { analyzing = r }
                        .popover(isPresented: Binding(get: { analyzing == r }, set: { if !$0 { analyzing = nil } })) {
                            ReferenceReportView(doc: doc, asset: r)
                        }
                        .contextMenu {
                            Button("Analyse") { analyzing = r }
                            Button("Remove") { doc.removeReference(r) }
                        }
                        .help("Click to analyse layout and colours")
                }
            }
        }
        .padding(.vertical, 8)
    }
}

private struct ReferenceThumb: View {
    let url: URL
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) } else { UI.raised }
        }
        // Off the main thread, once per file (not on every redraw).
        .task(id: url) {
            let u = url
            image = await Task.detached(priority: .utility) { try? ImageData.load(u) }.value
        }
        .frame(height: 48).frame(maxWidth: .infinity).clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(UI.border)).cursor(.pointingHand)
    }
}

/// What the on-device analysis found in a reference, with a button to take its colours.
private struct ReferenceReportView: View {
    @ObservedObject var doc: EditorDocument
    let asset: String
    @State private var report: ReferenceAnalyzer.Report?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(asset).font(UI.monoSmall).foregroundStyle(UI.dim)
            if let r = report {
                HStack(spacing: 4) {
                    ForEach(Array(zip(r.palette, r.shares)), id: \.0) { c, share in
                        VStack(spacing: 2) {
                            RoundedRectangle(cornerRadius: 3).fill(Color(arclight: .string(c)) ?? .gray).frame(width: 40, height: 28)
                            Text("\(Int(share * 100))%").font(UI.monoSmall).foregroundStyle(UI.faint)
                        }
                    }
                }
                Text("\(r.tone.capitalized), contrast \(String(format: "%.1f", r.contrast)):1").font(UI.small).foregroundStyle(UI.label2)
                ForEach(r.layout, id: \.self) { Text("• " + $0).font(UI.small).foregroundStyle(UI.text).fixedSize(horizontal: false, vertical: true) }
                Button("Use These Colours on This Page") { doc.applyPalette(r) }.buttonStyle(PillButtonStyle(primary: true))
                Text("Follow the structure, not the artwork: use your own photos and words.").font(UI.small).foregroundStyle(UI.faint)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(14).frame(width: 300)
        .task {
            let url = doc.assets.appendingPathComponent(asset)
            report = await Task.detached { (try? ImageData.load(url)).map(ReferenceAnalyzer.analyze) }.value
        }
    }
}
