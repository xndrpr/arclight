import AppKit
import ArclightCore
import SwiftUI

/// Export for the Thumbnail workspace: the open artboard (or every artboard of the page) as images.
struct StillExportSheet: View {
    let doc: EditorDocument
    @Binding var isPresented: Bool
    @State private var kind = Kind.youtube
    @State private var allArtboards = false
    @State private var transparent = false
    @State private var running = false
    @State private var results: [StillExporter.Result] = []
    @State private var error: String?
    @State private var dest: URL?

    enum Kind: String, CaseIterable { case youtube, jpg, png }

    private static let kinds: [(kind: Kind, title: String, detail: String)] = [
        (.youtube, "YouTube thumbnail", "JPG under YouTube's 2 MB limit, ready to upload. Best default."),
        (.jpg, "JPG · full size", "The artboard at its own size, high quality."),
        (.png, "PNG", "Lossless, optionally with a transparent background."),
    ]

    /// What `kind` writes for `a`: YouTube at 1280×720 turned to the artboard's orientation, JPG and PNG at its size.
    static func options(_ kind: Kind, for a: Artboard, transparent: Bool = false) -> StillExporter.Options {
        var o: StillExporter.Options
        switch kind {
        case .youtube: o = .youtube; o.scale = StillExporter.youtubeScale(for: a)
        case .jpg: o = .init(); o.format = .jpg
        case .png: o = .init(); o.format = .png; o.transparent = transparent
        }
        return o
    }

    /// A card's line, led by the pixel size(s) it writes for `boards`: "720×1280 · JPG under…".
    static func detail(_ kind: Kind, boards: [Artboard]) -> String {
        let line = kinds.first { $0.kind == kind }?.detail ?? ""
        var sizes: [String] = []
        for a in boards {
            let (w, h) = StillExporter.pixelSize(of: a, scale: options(kind, for: a).scale)
            if !sizes.contains("\(w)×\(h)") { sizes.append("\(w)×\(h)") }
        }
        guard !sizes.isEmpty else { return line }
        return sizes.prefix(3).joined(separator: ", ") + (sizes.count > 3 ? "…" : "") + " · " + line
    }

    var body: some View {
        let outDir = dest ?? doc.url.appendingPathComponent("exports")
        let page = doc.openThumbnail
        let boards = page.map(exported) ?? []
        VStack(alignment: .leading, spacing: 16) {
            ExportParts.header(summary(page))
            VStack(spacing: 6) {
                ForEach(Self.kinds, id: \.kind) { k in
                    FormatCard(title: k.title, detail: Self.detail(k.kind, boards: boards), on: kind == k.kind) {
                        kind = k.kind
                    }
                }
            }
            if kind == .png {
                ExportParts.row("Alpha", width: 66) {
                    Toggle("Transparent background", isOn: $transparent).toggleStyle(.checkbox).font(UI.font)
                }
            }
            if let page, page.artboards.count > 1 {
                ExportParts.row("Artboards", width: 66) {
                    Toggle("All \(page.artboards.count) artboards (variants and covers)", isOn: $allArtboards)
                        .toggleStyle(.checkbox).font(UI.font)
                }
            }
            ExportParts.folder(outDir, width: 66, dest: $dest)
            if let error { Text(error).font(UI.small).foregroundStyle(UI.danger).textSelection(.enabled) }
            if !results.isEmpty {
                ExportParts.results(count: results.count) {
                    ForEach(results, id: \.url) { r in
                        HStack(spacing: 8) {
                            Text(r.url.lastPathComponent).font(UI.monoSmall).foregroundStyle(UI.text)
                            Text("\(String(r.width))×\(String(r.height)) · \(Format.bytes(r.bytes))").font(UI.monoSmall)
                                .foregroundStyle(r.overLimit ? UI.danger : UI.dim)
                            if r.overLimit { Text("over 2 MB").font(UI.small).foregroundStyle(UI.danger) }
                        }
                    }
                }
            }
            HStack {
                if !results.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(results.map(\.url)) }
                        .buttonStyle(PillButtonStyle())
                }
                Spacer()
                Button("Close") { isPresented = false }.buttonStyle(PillButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Export") { run(outDir) }.buttonStyle(PillButtonStyle(primary: true))
                    .keyboardShortcut(.defaultAction).disabled(running || page == nil)
            }
        }
        .padding(20).frame(width: 540).background(UI.panel)
        .themedRoot()
    }

    private func summary(_ page: ArclightCore.Thumbnail?) -> String {
        guard let page else { return "Nothing to export" }
        if allArtboards && page.artboards.count > 1 {
            return "“\(page.name ?? page.id)” · \(page.artboards.count) artboards"
        }
        let a = doc.target.artboardId.flatMap { page.artboard($0) }
        return "“\(a?.name ?? a?.id ?? "")” · \(a?.width ?? 0)×\(a?.height ?? 0)"
    }

    /// The artboards Export writes: the open one, or all of the page's.
    private func exported(_ page: ArclightCore.Thumbnail) -> [Artboard] {
        allArtboards ? page.artboards : page.artboards.filter { $0.id == doc.target.artboardId }
    }

    private func run(_ dir: URL) {
        doc.saveNow()
        guard let page = doc.openThumbnail else { return }
        let boards = exported(page)
        let project = doc.store.project, assets = doc.assets, kind = kind, alpha = transparent
        running = true; results = []; error = nil
        doc.busy = "Exporting…"
        let d = doc
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let ex = StillExporter(renderer: try Renderer())
                var out: [StillExporter.Result] = []
                for a in boards {
                    let o = Self.options(kind, for: a, transparent: alpha)
                    let name = "\(page.id)_\(a.id).\(o.format.ext)"
                    out.append(
                        try ex.export(
                            artboard: a, thumbnail: page, project: project, assets: assets,
                            to: dir.appendingPathComponent(name), options: o))
                }
                DispatchQueue.main.async {
                    results = out; running = false; d.busy = nil; d.flash("Export finished")
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = "\(error)"; running = false; d.busy = nil
                }
            }
        }
    }
}
