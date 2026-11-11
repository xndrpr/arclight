import AppKit
import ArclightCore
import CoreText
import SwiftUI

/// Empty-state line for a section.
private struct EmptyNote: View {
    let text: String
    var body: some View {
        Text(text).font(UI.small).foregroundStyle(UI.faint).fixedSize(horizontal: false, vertical: true).padding(
            .horizontal, 2)
    }
}

// MARK: Images

struct ImagesSection: View {
    @ObservedObject var doc: EditorDocument
    var body: some View {
        let files = LibraryModel.files(.image, in: doc.url)
        if files.isEmpty { EmptyNote(text: "Import PNG, JPEG or HEIC files to use them as image layers.") }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], spacing: 6) {
            ForEach(files, id: \.self) { u in ImageCell(doc: doc, url: u) }
        }
    }
}

private struct ImageCell: View {
    @ObservedObject var doc: EditorDocument
    let url: URL
    @State private var image: CGImage?
    @State private var hover = false

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Checker()
                if let image { Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit) }
                if hover {
                    Button {
                        doc.addImageLayer(url.lastPathComponent)
                    } label: {
                        Label("Add", systemImage: "plus").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(
                            UI.onAccent
                        )
                        .padding(.horizontal, 7).frame(height: 20).background(Capsule().fill(UI.accent)).hitArea()
                    }
                    .buttonStyle(.plain).cursor(.pointingHand).help("Add to scene as an image layer")
                }
            }
            .frame(height: 54).clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(hover ? UI.fieldBorder : UI.border, lineWidth: 1))
            Text(url.lastPathComponent).font(.system(size: 9.5)).foregroundStyle(UI.label2).lineLimit(1).truncationMode(
                .middle)
        }
        .onHover { h in withMotion(UI.fade) { hover = h } }
        .help("\(url.lastPathComponent) — hover and click Add, or drag the file onto the viewer")
        .contextMenu {
            Button("Add to scene") { doc.addImageLayer(url.lastPathComponent) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .task(id: url) { image = await Self.load(url) }
    }

    private static func load(_ url: URL) async -> CGImage? {
        await Task.detached(priority: .utility) {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                let cg = CGImageSourceCreateThumbnailAtIndex(
                    src, 0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 220,
                    ] as CFDictionary)
            else { return nil }
            return cg
        }.value
    }
}

// MARK: Audio

struct AudioSection: View {
    @ObservedObject var doc: EditorDocument
    var body: some View {
        let files = LibraryModel.files(.audio, in: doc.url)
        if files.isEmpty {
            EmptyNote(text: "Import a voiceover or music (WAV, M4A, MP3) to time animation against it.")
        }
        VStack(spacing: 2) {
            ForEach(files, id: \.self) { u in AudioRow(doc: doc, url: u) }
        }
    }
}

private struct AudioRow: View {
    @ObservedObject var doc: EditorDocument
    let url: URL
    @State private var duration: Double?

    var body: some View {
        let inUse = doc.scene.audio?.src == url.lastPathComponent
        HStack(spacing: 8) {
            Image(systemName: "waveform").font(.system(size: 11)).foregroundStyle(inUse ? UI.text : UI.dim)
            VStack(alignment: .leading, spacing: 1) {
                Text(url.lastPathComponent).font(UI.small).foregroundStyle(UI.text).lineLimit(1).truncationMode(.middle)
                Text(duration.map { Self.time($0) } ?? "—").font(UI.monoSmall).foregroundStyle(UI.dim)
            }
            Spacer(minLength: 0)
            if inUse {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(UI.text).help(
                    "Scene audio")
            } else {
                IconButton(symbol: "speaker.wave.2", help: "Use as scene audio") {
                    doc.useAsSceneAudio(url.lastPathComponent)
                }
            }
        }
        .padding(.horizontal, 4).frame(height: 34).hitArea()
        .contextMenu {
            Button("Use as scene audio") { doc.useAsSceneAudio(url.lastPathComponent) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .task(id: url) { duration = await Task.detached(priority: .utility) { SceneAudio.info(url)?.duration }.value }
    }

    private static func time(_ d: Double) -> String {
        let s = Int(d.rounded(.down))
        return String(format: "%d:%02d.%d", s / 60, s % 60, Int((d - Double(s)) * 10))
    }
}

// MARK: Fonts

struct FontsSection: View {
    @ObservedObject var doc: EditorDocument
    var body: some View {
        let files = LibraryModel.files(.font, in: doc.url)
        if files.isEmpty {
            EmptyNote(text: "Fonts in the project's fonts/ folder travel with it and render the same on any Mac.")
        }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(files, id: \.self) { u in
                ForEach(Self.names(u), id: \.self) { ps in
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Motion 72%").font(.custom(ps, size: 20)).foregroundStyle(UI.text).lineLimit(1)
                        Text(ps).font(UI.monoSmall).foregroundStyle(UI.dim).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(.horizontal, 4)
                    .contextMenu {
                        Button("Copy font name") {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ps, forType: .string)
                        }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                    }
                }
            }
        }
    }

    /// PostScript names in a font file (the value to use for `font`).
    private static func names(_ url: URL) -> [String] {
        let ds = (CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor]) ?? []
        let n = ds.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
        return n.isEmpty ? [url.deletingPathExtension().lastPathComponent] : n
    }
}

// MARK: Symbols

struct SymbolsSection: View {
    @ObservedObject var doc: EditorDocument
    @State private var query = ""

    var body: some View {
        let all = Symbols.all(project: doc.url).filter {
            query.isEmpty || $0.id.localizedCaseInsensitiveContains(query)
        }
        let packs = all.uniqued(by: \.pack).map(\.pack)
        VStack(alignment: .leading, spacing: 8) {
            Text(
                doc.selectedRepeater.map {
                    "Click a symbol to add it to \($0). Right-click for a separate symbol layer."
                }
                    ?? "Click a symbol to add it as a layer. Right-click for a crowd (repeater) of it."
            )
            .font(.system(size: 10.5)).foregroundStyle(UI.dim).fixedSize(horizontal: false, vertical: true)
            FieldBox { TextField("Search symbols", text: $query) }
            ForEach(packs, id: \.self) { pack in
                Text(pack.uppercased()).font(.system(size: 9.5, weight: .semibold)).tracking(0.7).foregroundStyle(
                    UI.faint
                ).padding(.top, 2)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 4)], spacing: 4) {
                    ForEach(all.filter { $0.pack == pack }, id: \.id) { s in SymbolCell(doc: doc, info: s) }
                }
            }
        }
    }
}

private struct SymbolCell: View {
    @ObservedObject var doc: EditorDocument
    let info: Symbols.Info
    @State private var hover = false

    var body: some View {
        Button {
            doc.useSymbolInSelectedRepeater(info.id)
        } label: {  // adds a symbol layer when no repeater is selected
            SymbolThumb(id: info.id, project: doc.url, color: hover ? UI.text : UI.label2)
                .padding(6).frame(height: 40).frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 5).fill(hover ? UI.hover : UI.field))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(UI.border, lineWidth: 1))
                .hitArea()
        }
        .buttonStyle(.plain).onHover { h in withMotion(UI.fade) { hover = h } }.cursor(.pointingHand)
        .help("\(info.name) · \(info.id) — click to add " + (doc.selectedRepeater.map { "to \($0)" } ?? "as a layer"))
        .contextMenu {
            Button("Add as Symbol Layer") { doc.addSymbolLayer(info.id) }
            Button("Add to Selected Repeater") { doc.useSymbolInSelectedRepeater(info.id) }.disabled(
                doc.selectedRepeater == nil)
            Button("New Repeater (Crowd) of \(info.name)") { doc.addRepeater(symbol: info.id) }
            Button("Copy id") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(info.id, forType: .string)
            }
        }
    }
}

// MARK: Templates

struct TemplatesSection: View {
    @ObservedObject var doc: EditorDocument
    var body: some View {
        let files = LibraryModel.templateFiles(project: doc.url)
        VStack(alignment: .leading, spacing: 2) {
            if files.isEmpty {
                EmptyNote(text: "Right-click a scene → Save as template… to reuse it here and in other projects.")
            }
            ForEach(files) { f in TemplateRow(doc: doc, file: f) }
            Button {
                LibrarySheets.templates(doc, mode: .newScene)
            } label: {
                Label("Browse all templates…", systemImage: "square.grid.2x2").font(UI.small).foregroundStyle(UI.label2)
                    .hitArea()
            }
            .buttonStyle(.plain).cursor(.pointingHand).padding(.top, 6).padding(.horizontal, 4)
        }
    }
}

private struct TemplateRow: View {
    @ObservedObject var doc: EditorDocument
    let file: LibraryModel.TemplateFile
    @State private var hover = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(file.template.name).font(UI.small).foregroundStyle(UI.text).lineLimit(1)
                Text("\(file.scope == .user ? "all projects" : "this project") · \(file.template.params.count) params")
                    .font(UI.monoSmall).foregroundStyle(UI.dim).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        // Hover buttons sit on top (opaque over a long name), so the text never moves or re-truncates.
        .overlay(alignment: .trailing) {
            if hover {
                HStack(spacing: 8) {
                    IconButton(symbol: "plus.rectangle", help: "New scene from this template") {
                        doc.newScene(from: file.template, params: [:])
                    }
                    IconButton(symbol: "trash", help: "Delete template") { doc.deleteTemplate(file) }
                }
                .padding(.leading, 8).frame(maxHeight: .infinity).background(UI.hover.background(UI.panel))
            }
        }
        .padding(.horizontal, 4).frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 5).fill(hover ? UI.hover : .clear))
        .hitArea()
        .onHover { h in withMotion(UI.fade) { hover = h } }
        .contextMenu {
            Button("New scene from template") { doc.newScene(from: file.template, params: [:]) }
            Button("Insert into current scene") { doc.insertTemplate(file.template, params: [:]) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
            Divider()
            Button("Delete…") { doc.deleteTemplate(file) }
        }
    }
}
