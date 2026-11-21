import AppKit
import ArclightCore
import SwiftUI

/// The export that is running (or last ran) for a project. Kept by the document, so hiding the sheet doesn't lose
/// it: the top bar's "Exporting…" brings the sheet back.
@Observable final class ExportJob {
    /// The sheet's choices, kept for the project while it is open: reopening the sheet shows them again.
    var format = ExportFormat.mp4
    var scale = 1.0
    var which = ExportSheet.Which.current
    var transparent = false
    var dest: URL?
    var progress: Double?
    var results: [URL] = []
    var error: String?
    /// Set by Cancel; the exporter asks between frames.
    private let stopFlag = StopFlag()
    var running: Bool { progress.map { $0 < 1 } ?? false }

    func start() { progress = 0; results = []; error = nil; stopFlag.set(false) }
    func cancel() { stopFlag.set(true) }
    var isCancelled: () -> Bool { { [stopFlag] in stopFlag.get() } }
}

final class StopFlag: @unchecked Sendable {
    private var on = false
    private let lock = NSLock()
    func set(_ v: Bool) { lock.withLock { on = v } }
    func get() -> Bool { lock.withLock { on } }
}

struct ExportSheet: View {
    let doc: EditorDocument
    @Bindable var job: ExportJob
    @Binding var isPresented: Bool
    private var format: ExportFormat {
        get { job.format }
        nonmutating set { job.format = newValue }
    }
    private var scale: Double { job.scale }
    /// Which scenes: the open one, all of them back to back in one file, or each in its own file.
    enum Which: Hashable { case current, joined, separate }
    private var which: Which { job.which }
    private var allScenes: Bool { which != .current }
    private var progress: Double? { job.progress }
    private var results: [URL] { job.results }
    private var error: String? { job.error }
    private var dest: URL? { job.dest }
    private var transparent: Bool { job.transparent }

    init(doc: EditorDocument, isPresented: Binding<Bool>, which: Which? = nil) {
        self.doc = doc; job = doc.exportJob; _isPresented = isPresented
        if let which { doc.exportJob.which = which }
    }

    var body: some View {
        let outDir = dest ?? doc.url.appendingPathComponent("exports")
        let running = progress != nil && progress! < 1
        VStack(alignment: .leading, spacing: 16) {
            ExportParts.header(summary)
            VStack(spacing: 6) {
                ForEach(Self.formats, id: \.format) { f in
                    FormatCard(title: f.title, detail: f.detail, on: format == f.format) { format = f.format }
                }
            }
            if format == .prores || format == .png {
                ExportParts.row("Alpha") {
                    Toggle("Transparent background (for overlaying in your video editor)", isOn: $job.transparent)
                        .toggleStyle(.checkbox).font(UI.font)
                }
            }
            ExportParts.row("Size") {
                Picker("", selection: $job.scale) {
                    ForEach([0.5, 1.0, 2.0], id: \.self) { s in
                        Text("\(Int(doc.canvasSize.width * s))×\(Int(doc.canvasSize.height * s))").tag(s)
                    }
                }.pickerStyle(.segmented).labelsHidden()
            }
            if doc.scenes.count > 1 {
                ExportParts.row("Scenes") {
                    Picker("", selection: $job.which) {
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
            ExportParts.folder(outDir, dest: $job.dest)
            if let progress {
                HStack(spacing: 8) {
                    if running { ProgressView().controlSize(.small).scaleEffect(0.7) }
                    ProgressView(value: progress).tint(UI.accent)
                    Text("\(Int(progress * 100))%").font(UI.monoSmall).foregroundStyle(UI.dim).frame(width: 36)
                }
            }
            if let error { Text(error).font(UI.small).foregroundStyle(UI.danger).textSelection(.enabled) }
            if !results.isEmpty {
                ExportParts.results(count: results.count) {
                    ForEach(results, id: \.self) { u in
                        Text(u.lastPathComponent).font(UI.monoSmall).foregroundStyle(UI.text)
                    }
                }
            }
            HStack {
                if !results.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(results) }.buttonStyle(
                        PillButtonStyle())
                }
                Spacer()
                if running {
                    Button("Cancel Export") { job.cancel() }.buttonStyle(PillButtonStyle())
                        .help("Stop the export; the unfinished file is removed")
                }
                Button(running ? "Hide" : "Close") { isPresented = false }.buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .help(running ? "Keeps exporting — click “Exporting…” in the top bar to come back here" : "")
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
        .onChange(of: job.format) { _, f in job.transparent = f == .prores }
    }

    /// A scene's file when each scene gets its own: numbered in the Scenes list's order when there are several,
    /// so Finder and video editors list them in that order ("03 scene-2b").
    static func fileName(_ s: Scene, at i: Int, of n: Int) -> String {
        guard n > 1 else { return s.id }
        let digits = String(n).count
        return String(repeating: "0", count: max(0, max(2, digits) - String(i + 1).count)) + "\(i + 1) \(s.id)"
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

    private func still(_ dir: URL) {
        doc.saveNow()
        let scene = doc.scene, project = doc.project, assets = doc.assets, t = doc.viewTime, sc = scale,
            alpha = transparent && format != .mp4
        job.error = nil
        let job = job
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let u = try Exporter(renderer: try Renderer()).exportStill(
                    scene: scene, project: project, assets: assets, time: t,
                    to: dir.appendingPathComponent("\(scene.id)@\(String(format: "%.2f", t))s.png"), scale: sc,
                    transparent: alpha)
                DispatchQueue.main.async {
                    job.results = [u]; job.progress = 1
                }
            } catch { DispatchQueue.main.async { job.error = "\(error)" } }
        }
    }

    private func run(_ dir: URL) {
        doc.saveNow()
        let scenes = allScenes ? doc.scenes : [doc.scene]
        let project = doc.project, assets = doc.assets, joined = which == .joined && scenes.count > 1
        let joinedName = Exporter.joinedName(project.name)
        var o = ExportOptions(); o.format = format; o.scale = scale
        if format == .prores || format == .png { o.transparent = transparent }
        job.start()
        doc.busy = "Exporting…"
        let d = doc, job = job, stop = job.isCancelled
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let ex = Exporter(renderer: try Renderer())
                ex.isCancelled = stop
                var out: [URL] = []
                if joined {
                    let r = try ex.export(
                        scenes: scenes, project: project, assets: assets,
                        to: dir.appendingPathComponent("\(joinedName).\(format.ext)"), options: o
                    ) { f, n in
                        if f % 5 == 0 || f == n {
                            let p = Double(f) / Double(n)
                            DispatchQueue.main.async { job.progress = p; d.busy = "Exporting \(Int(p * 100))%" }
                        }
                    }
                    out.append(r.url)
                }
                for (i, s) in (joined ? [] : scenes).enumerated() {
                    if stop() { throw CancellationError() }
                    let r = try ex.export(
                        scene: s, project: project, assets: assets,
                        to: dir.appendingPathComponent("\(Self.fileName(s, at: i, of: scenes.count)).\(format.ext)"),
                        options: o
                    ) { f, n in
                        if f % 5 == 0 || f == n {
                            let p = (Double(i) + Double(f) / Double(n)) / Double(scenes.count)
                            DispatchQueue.main.async {
                                job.progress = p; d.busy = "Exporting \(Int(p * 100))%"
                            }
                        }
                    }
                    out.append(r.url)
                }
                DispatchQueue.main.async {
                    job.results = out; job.progress = 1; d.busy = nil; d.flash("Export finished")
                }
            } catch is CancellationError {
                DispatchQueue.main.async {
                    job.error = "Export cancelled."; job.progress = nil; d.busy = nil; d.flash("Export cancelled")
                }
            } catch {
                DispatchQueue.main.async {
                    job.error = "\(error)"; job.progress = nil; d.busy = nil
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

/// The pieces both export sheets share.
enum ExportParts {
    /// "Export" and what will be exported.
    static func header(_ summary: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Export").font(.system(size: 15, weight: .semibold)).foregroundStyle(UI.text)
            Text(summary).font(UI.small).foregroundStyle(UI.dim)
        }
    }

    /// A labelled row: the label in a column `width` wide, then the controls.
    static func row<C: View>(_ label: String, width: CGFloat = 60, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .center) {
            Text(label).font(UI.small).foregroundStyle(UI.label2).frame(width: width, alignment: .leading)
            c()
        }
    }

    /// Where the files go, and Change… to pick another folder.
    static func folder(_ dir: URL, width: CGFloat = 60, dest: Binding<URL?>) -> some View {
        row("Folder", width: width) {
            HStack {
                Text(dir.tildePath).font(UI.monoSmall).foregroundStyle(UI.label2).lineLimit(1).truncationMode(.head)
                Spacer()
                Button("Change…") { if let u = FilePicker.folder(canCreate: true) { dest.wrappedValue = u } }
                    .buttonStyle(PillButtonStyle())
            }
        }
    }

    /// The files an export wrote. Exporting every scene lists dozens: they scroll instead of growing the sheet
    /// past the window.
    static func results<C: View>(count: Int, @ViewBuilder _ c: () -> C) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) { c() }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: min(CGFloat(count) * 17, 140))
    }
}
