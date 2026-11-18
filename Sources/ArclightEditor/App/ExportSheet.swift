import AppKit
import ArclightCore
import SwiftUI

struct ExportSheet: View {
    @ObservedObject var doc: EditorDocument
    @Binding var isPresented: Bool
    @State private var format = ExportFormat.mp4
    @State private var scale = 1.0
    /// Which scenes: the open one, all of them back to back in one file, or each in its own file.
    enum Which: Hashable { case current, joined, separate }
    @State private var which: Which
    private var allScenes: Bool { which != .current }
    @State private var progress: Double?
    @State private var results: [URL] = []
    @State private var error: String?
    @State private var dest: URL?
    @State private var transparent = false

    init(doc: EditorDocument, isPresented: Binding<Bool>, which: Which = .current) {
        self.doc = doc; _isPresented = isPresented; _which = State(initialValue: which)
    }

    var body: some View {
        let outDir = dest ?? doc.url.appendingPathComponent("exports")
        let running = progress != nil && progress! < 1
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Export").font(.system(size: 15, weight: .semibold)).foregroundStyle(UI.text)
                Text(summary).font(UI.small).foregroundStyle(UI.dim)
            }
            VStack(spacing: 6) {
                ForEach(Self.formats, id: \.format) { f in
                    FormatCard(title: f.title, detail: f.detail, on: format == f.format) { format = f.format }
                }
            }
            if format == .prores || format == .png {
                row("Alpha") {
                    Toggle("Transparent background (for overlaying in your video editor)", isOn: $transparent)
                        .toggleStyle(.checkbox).font(UI.font)
                }
            }
            row("Size") {
                Picker("", selection: $scale) {
                    ForEach([0.5, 1.0, 2.0], id: \.self) { s in
                        Text("\(Int(doc.canvasSize.width * s))×\(Int(doc.canvasSize.height * s))").tag(s)
                    }
                }.pickerStyle(.segmented).labelsHidden()
            }
            if doc.scenes.count > 1 {
                row("Scenes") {
                    Picker("", selection: $which) {
                        Text("This scene").tag(Which.current)
                        Text("All \(doc.scenes.count), joined").tag(Which.joined)
                        Text("All, separate files").tag(Which.separate)
                    }.pickerStyle(.segmented).labelsHidden()
                }
                if which == .joined {
                    Text(
                        "One file: " + doc.scenes.map { $0.name ?? $0.id }.joined(separator: " → ")
                            + ". Drag scenes in the Scenes list to change the order."
                    )
                    .font(UI.small).foregroundStyle(UI.dim).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 68)
                }
            }
            row("Folder") {
                HStack {
                    Text(outDir.tildePath).font(UI.monoSmall).foregroundStyle(UI.label2)
                        .lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Change…") {
                        if let u = FilePicker.folder(canCreate: true) { dest = u }
                    }.buttonStyle(PillButtonStyle())
                }
            }
            if let progress {
                HStack(spacing: 8) {
                    if running { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    ProgressView(value: progress).tint(UI.accent)
                    Text("\(Int(progress * 100))%").font(UI.monoSmall).foregroundStyle(UI.dim).frame(width: 36)
                }
            }
            if let error { Text(error).font(UI.small).foregroundStyle(UI.danger).textSelection(.enabled) }
            if !results.isEmpty {
                // Exporting every scene lists dozens of files: scroll them instead of growing the sheet past the
                // window.
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(results, id: \.self) { u in
                            Text(u.lastPathComponent).font(UI.monoSmall).foregroundStyle(UI.text)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(CGFloat(results.count) * 17, 140))
            }
            HStack {
                if !results.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(results) }.buttonStyle(
                        PillButtonStyle())
                }
                Spacer()
                Button(running ? "Hide" : "Close") { isPresented = false }.buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Save current frame as PNG") { still(outDir) }.buttonStyle(PillButtonStyle())
                    .help(
                        "Writes the frame at the playhead (\(String(format: "%.2f", doc.viewTime))s) as one PNG — e.g. for a thumbnail"
                    )
                Button("Export") { run(outDir) }.buttonStyle(PillButtonStyle(primary: true)).keyboardShortcut(
                    .defaultAction
                )
                .disabled(running)
            }
        }
        .padding(20).frame(width: 540).background(UI.panel)
        .themedRoot()  // a sheet is its own window: follow theme changes while it's open
        .onChange(of: format) { _, f in transparent = f == .prores }
    }

    private static let formats: [(format: ExportFormat, title: String, detail: String)] = [
        (.mp4, "MP4 · H.264", "Plays everywhere: web, social, slides. Best default."),
        (.hevc, "HEVC · H.265", "Same quality at about half the file size; recent devices only."),
        (.prores, "ProRes 4444", "Large, lossless-quality master with transparency, for video editors."),
        (.png, "PNG sequence", "One image per frame (optionally transparent), for compositing tools."),
    ]

    private var summary: String {
        let fps = doc.fps, d = allScenes ? doc.scenes.reduce(0) { $0 + $1.duration } : doc.scene.duration
        let frames = Int((d * fps).rounded(.up))
        let what =
            which == .joined
            ? "\(doc.scenes.count) scenes in one file"
            : allScenes ? "\(doc.scenes.count) scenes" : "“\(doc.scene.name ?? doc.scene.id)”"
        return "\(what) · \(fmt((d * 100).rounded() / 100)) s · \(frames) frames at \(fmt(fps)) fps"
            + ((allScenes ? doc.scenes : [doc.scene]).contains { !$0.audibleClips.isEmpty } && format != .png
                ? " · with audio" : "")
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .center) {
            Text(label).font(UI.small).foregroundStyle(UI.label2).frame(width: 60, alignment: .leading)
            c()
        }
    }

    private func still(_ dir: URL) {
        doc.saveNow()
        let scene = doc.scene, project = doc.project, assets = doc.assets, t = doc.viewTime, sc = scale,
            alpha = transparent && format != .mp4
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let u = try Exporter(renderer: try Renderer()).exportStill(
                    scene: scene, project: project, assets: assets, time: t,
                    to: dir.appendingPathComponent("\(scene.id)@\(String(format: "%.2f", t))s.png"), scale: sc,
                    transparent: alpha)
                DispatchQueue.main.async {
                    results = [u]; progress = 1
                }
            } catch { DispatchQueue.main.async { self.error = "\(error)" } }
        }
    }

    private func run(_ dir: URL) {
        doc.saveNow()
        let scenes = allScenes ? doc.scenes : [doc.scene]
        let project = doc.project, assets = doc.assets, joined = which == .joined && scenes.count > 1
        let joinedName = Exporter.joinedName(project.name)
        var o = ExportOptions(); o.format = format; o.scale = scale
        if format == .prores || format == .png { o.transparent = transparent }
        progress = 0; results = []; error = nil
        doc.busy = "Exporting…"
        let d = doc
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let ex = Exporter(renderer: try Renderer())
                var out: [URL] = []
                if joined {
                    let r = try ex.export(
                        scenes: scenes, project: project, assets: assets,
                        to: dir.appendingPathComponent("\(joinedName).\(format.ext)"), options: o
                    ) { f, n in
                        if f % 5 == 0 || f == n {
                            let p = Double(f) / Double(n)
                            DispatchQueue.main.async { progress = p; d.busy = "Exporting \(Int(p * 100))%" }
                        }
                    }
                    out.append(r.url)
                }
                for (i, s) in (joined ? [] : scenes).enumerated() {
                    let r = try ex.export(
                        scene: s, project: project, assets: assets,
                        to: dir.appendingPathComponent("\(s.id).\(format.ext)"), options: o
                    ) { f, n in
                        if f % 5 == 0 || f == n {
                            let p = (Double(i) + Double(f) / Double(n)) / Double(scenes.count)
                            DispatchQueue.main.async {
                                progress = p; d.busy = "Exporting \(Int(p * 100))%"
                            }
                        }
                    }
                    out.append(r.url)
                }
                DispatchQueue.main.async {
                    results = out; progress = 1; d.busy = nil; d.flash("Export finished")
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = "\(error)"; progress = nil; d.busy = nil
                }
            }
        }
    }
}

/// One export format: title and a one-line "when to use it". The whole card is clickable.
struct FormatCard: View {
    let title: String
    let detail: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").font(.system(size: 13))
                    .foregroundStyle(on ? UI.accent : UI.faint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(UI.font.weight(.medium)).foregroundStyle(UI.text)
                    Text(detail).font(UI.small).foregroundStyle(UI.dim)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? UI.selected : (hover ? UI.hover : UI.raised)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(on ? UI.accent.opacity(0.6) : UI.border, lineWidth: 1))
            .hitArea()
        }
        .buttonStyle(.plain).onHover { hover = $0 }.cursor(.pointingHand)
    }
}
