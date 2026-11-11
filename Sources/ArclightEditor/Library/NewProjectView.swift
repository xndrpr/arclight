import AppKit
import ArclightCore
import SwiftUI

/// "New project": name, location, canvas, frame rate and a starting point (blank or any template, with previews
/// rendered at the chosen canvas). The template becomes the first scene with its default parameters.
struct NewProjectView: View {
    let create: (URL) -> Void
    let cancel: () -> Void
    @State private var name = "Untitled"
    @State private var location = LibraryModel.defaultProjectsDir
    @State private var preset = 0
    @State private var fps: Double = 30
    @State private var start: String?
    @State private var error: String?

    var body: some View {
        let p = EditorDocument.presets[preset]
        let templates = Templates.all(project: nil)
        HStack(spacing: 0) {
            form(templates: templates)
                .padding(24).frame(width: 290, alignment: .leading)
            Hairline(vertical: true)
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "Starting point").padding(.top, 24).padding(.horizontal, 6)
                ScrollView {
                    TemplateGrid(
                        templates: templates, selected: start, canvas: (p.w, p.h), blank: true,
                        minWidth: p.w < p.h ? 120 : 170,
                        pick: { start = $0.id }, pickBlank: { start = nil }
                    )
                    .padding(.horizontal, 18).padding(.bottom, 18)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(WindowDragArea())  // empty space moves the window (its content never does)
        .background(UI.bg)
        .frame(minWidth: 860, minHeight: 560)
    }

    @ViewBuilder private func form(templates: [Template]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Spacer().frame(height: 8)
            HStack(spacing: 8) {
                LogoMark(height: 15)
                Text("New project").font(.system(size: 18, weight: .semibold)).foregroundStyle(UI.text)
            }
            LabeledField("Name") { FieldBox { TextField("Untitled", text: $name).font(UI.font).onSubmit(make) } }
            LabeledField("Location") {
                HStack(spacing: 6) {
                    Text(location.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(UI.monoSmall).foregroundStyle(UI.label2).lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…", action: chooseLocation).buttonStyle(PillButtonStyle())
                }
            }
            LabeledField("Canvas") {
                Picker("", selection: $preset) {
                    ForEach(Array(EditorDocument.presets.enumerated()), id: \.offset) { i, p in
                        Text(verbatim: p.name).tag(i)
                    }
                }
                .labelsHidden()
            }
            LabeledField("Frame rate") {
                Picker("", selection: $fps) {
                    ForEach(EditorDocument.frameRates, id: \.self) { f in Text("\(fmt(f)) fps").tag(f) }
                }
                .labelsHidden()
            }
            LabeledField("Starts with") {
                Text(templates.first { $0.id == start }?.name ?? "Blank scene").font(UI.font).foregroundStyle(UI.text)
            }
            Spacer()
            if let error {
                Text(error).font(UI.small).foregroundStyle(Color.red.opacity(0.9)).fixedSize(
                    horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel", action: cancel).buttonStyle(PillButtonStyle()).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create project", action: make).buttonStyle(PillButtonStyle(primary: true)).keyboardShortcut(
                    .defaultAction)
            }
        }
    }

    private func chooseLocation() {
        let start =
            FileManager.default.fileExists(atPath: location.path)
            ? location : FileManager.default.homeDirectoryForCurrentUser
        if let u = FilePicker.folder(prompt: "Choose", canCreate: true, startingAt: start) { location = u }
    }

    private func make() {
        let p = EditorDocument.presets[preset]
        let t = start.flatMap { Templates.get($0, project: nil) }
        do {
            create(try LibraryModel.createProject(in: location, name: name, size: (p.w, p.h), fps: fps, template: t))
        } catch { self.error = "\(error)" }
    }
}

/// Thumbnail of a project's first scene (welcome window), rendered lazily and cached on disk.
struct ProjectThumb: View {
    let url: URL
    @State private var image: CGImage?
    var body: some View {
        ThumbImage(image: image, radius: 3)
            .task(id: url) { image = await LibraryThumbs.shared.project(url) }
    }
}
