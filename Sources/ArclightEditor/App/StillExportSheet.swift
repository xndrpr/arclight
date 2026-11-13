import AppKit
import ArclightCore
import SwiftUI

/// Export for the Preview workspace: the open artboard (or every artboard of the page) as images.
struct StillExportSheet: View {
    @ObservedObject var doc: EditorDocument
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
        (.youtube, "YouTube thumbnail", "1280×720 JPG under YouTube's 2 MB limit, ready to upload. Best default."),
        (.jpg, "JPG · full size", "The artboard at its own size, high quality."),
        (.png, "PNG", "Lossless, optionally with a transparent background."),
    ]

    var body: some View {
        let outDir = dest ?? doc.url.appendingPathComponent("exports")
        let page = doc.openPreview
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Export").font(.system(size: 15, weight: .semibold)).foregroundStyle(UI.text)
                Text(summary(page)).font(UI.small).foregroundStyle(UI.dim)
            }
            VStack(spacing: 6) {
                ForEach(Self.kinds, id: \.kind) { k in
                    FormatCard(title: k.title, detail: k.detail, on: kind == k.kind) { kind = k.kind }
                }
            }
            if kind == .png {
                row("Alpha") {
                    Toggle("Transparent background", isOn: $transparent).toggleStyle(.checkbox).font(UI.font)
                }
            }
            if let page, page.artboards.count > 1 {
                row("Artboards") {
                    Toggle("All \(page.artboards.count) artboards (variants and covers)", isOn: $allArtboards)
                        .toggleStyle(.checkbox).font(UI.font)
                }
            }
            row("Folder") {
                HStack {
                    Text(outDir.tildePath).font(UI.monoSmall).foregroundStyle(UI.label2)
                        .lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Change…") { if let u = FilePicker.folder(canCreate: true) { dest = u } }
                        .buttonStyle(PillButtonStyle())
                }
            }
            if let error { Text(error).font(UI.small).foregroundStyle(UI.danger).textSelection(.enabled) }
            if !results.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
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

    private func summary(_ page: ArclightCore.Preview?) -> String {
        guard let page else { return "Nothing to export" }
        if allArtboards && page.artboards.count > 1 { return "“\(page.name ?? page.id)” · \(page.artboards.count) artboards" }
        let a = doc.target.artboardId.flatMap { page.artboard($0) }
        return "“\(a?.name ?? a?.id ?? "")” · \(a?.width ?? 0)×\(a?.height ?? 0)"
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .center) {
            Text(label).font(UI.small).foregroundStyle(UI.label2).frame(width: 66, alignment: .leading)
            c()
        }
    }

    private func run(_ dir: URL) {
        doc.saveNow()
        guard let page = doc.openPreview else { return }
        let boards = allArtboards ? page.artboards : page.artboards.filter { $0.id == doc.target.artboardId }
        let project = doc.store.project, assets = doc.assets, kind = kind, alpha = transparent
        running = true; results = []; error = nil
        doc.busy = "Exporting…"
        let d = doc
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let ex = StillExporter(renderer: try Renderer())
                var out: [StillExporter.Result] = []
                for a in boards {
                    var o: StillExporter.Options
                    switch kind {
                    case .youtube: o = .youtube; o.scale = StillExporter.youtubeScale(for: a)
                    case .jpg: o = .init(); o.format = .jpg
                    case .png: o = .init(); o.format = .png; o.transparent = alpha
                    }
                    let name = "\(page.id)_\(a.id).\(o.format.ext)"
                    out.append(
                        try ex.export(
                            artboard: a, preview: page, project: project, assets: assets,
                            to: dir.appendingPathComponent(name), options: o))
                }
                DispatchQueue.main.async {
                    results = out; running = false; d.busy = nil; d.flash("Export finished")
                }
            } catch {
                DispatchQueue.main.async { self.error = "\(error)"; running = false; d.busy = nil }
            }
        }
    }
}
