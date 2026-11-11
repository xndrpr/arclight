import ArclightCore
import SwiftUI

/// "Save scene as template…": name, id, description, category, scope, and which values become parameters.
struct SaveTemplateSheet: View {
    @ObservedObject var doc: EditorDocument
    let scene: Scene
    let close: () -> Void
    @State private var name = ""
    @State private var id = ""
    @State private var idEdited = false
    @State private var description = ""
    @State private var category = ""
    @State private var scope = Templates.Scope.project
    @State private var picked: Set<String> = []

    var body: some View {
        let cands = LibraryModel.candidates(scene)
        let clash = Templates.all(project: doc.url).contains { $0.id == LibraryModel.slug(id) }
        VStack(spacing: 0) {
            HStack {
                Text("Save scene as template").font(.system(size: 14, weight: .semibold)).foregroundStyle(UI.text)
                Spacer()
                Text(scene.name ?? scene.id).font(UI.small).foregroundStyle(UI.dim)
            }
            .padding(.horizontal, 16).frame(height: 52)
            Hairline()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    fields(clash: clash)
                    Hairline()
                    ParamPicker(candidates: cands, picked: $picked)
                }
                .padding(16)
            }
            Hairline()
            SheetFooter(
                cancel: close, confirmTitle: clash ? "Replace template" : "Save template",
                confirmDisabled: name.trimmingCharacters(in: .whitespaces).isEmpty || LibraryModel.slug(id).isEmpty,
                confirm: {
                    let picks = cands.filter { picked.contains($0.id) }
                    if doc.saveTemplate(
                        from: scene, id: LibraryModel.slug(id), name: name,
                        description: description.isEmpty ? nil : description,
                        category: category, scope: scope, picks: picks)
                    {
                        close()
                    }
                }
            ) {
                Text("\(picked.count) parameter\(picked.count == 1 ? "" : "s")").font(UI.small).foregroundStyle(UI.dim)
            }
        }
        .background(UI.bg)
        .onAppear {
            name = scene.name ?? scene.id
            id = LibraryModel.slug(name).isEmpty ? scene.id : LibraryModel.slug(name)
            // Texts and counter values are the usual parameters.
            picked = Set(cands.filter { $0.prop == "text" || $0.prop == "value" || $0.kind == "symbol" }.map(\.id))
        }
    }

    @ViewBuilder private func fields(clash: Bool) -> some View {
        let cats = Templates.all(project: doc.url).compactMap(\.category).uniqued { $0 }
        LabeledField("Name") { FieldBox { TextField("Brand stat", text: $name).font(UI.font) } }
            .onChange(of: name) { _, n in
                if !idEdited { id = LibraryModel.slug(n).isEmpty ? scene.id : LibraryModel.slug(n) }
            }
        LabeledField(
            "Id", note: clash ? "A template with this id exists — saving replaces it in the chosen scope." : nil
        ) {
            FieldBox {
                TextField(
                    "brand-stat",
                    text: Binding(
                        get: { id },
                        set: { v in
                            id = v.lowercased().map {
                                $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") ? String($0) : "-"
                            }.joined()
                            idEdited = true
                        }))
            }
        }
        LabeledField("Description") {
            FieldBox {
                TextField("What it is for", text: $description, axis: .vertical).font(UI.font).lineLimit(1...3).padding(
                    .vertical, 5)
            }
        }
        LabeledField("Category") {
            HStack(spacing: 6) {
                FieldBox { TextField("Text, Numbers…", text: $category) }
                Menu {
                    ForEach(cats, id: \.self) { c in Button(c) { category = c } }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 10))
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().cursor(.pointingHand).disabled(
                    cats.isEmpty)
            }
        }
        LabeledField("Save to") {
            Picker("", selection: $scope) {
                Text("This project").tag(Templates.Scope.project)
                Text("All projects").tag(Templates.Scope.user)
            }
            .pickerStyle(.segmented).labelsHidden()
        }
    }
}

struct LabeledField<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder let content: Content
    init(_ title: String, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title; self.note = note; self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(UI.small).foregroundStyle(UI.label2)
            content
            if let note { Text(note).font(.system(size: 10.5)).foregroundStyle(UI.dim) }
        }
    }
}

/// Checkbox list of a scene's simple values (texts, numbers, colours, symbols), grouped by layer.
private struct ParamPicker: View {
    let candidates: [LibraryModel.ParamCandidate]
    @Binding var picked: Set<String>

    var body: some View {
        let layers = candidates.map(\.layer).uniqued { $0 }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SmallCapsLabel("Parameters")
                Spacer()
                Button("All") { picked = Set(candidates.map(\.id)) }.buttonStyle(.plain).font(UI.small).foregroundStyle(
                    UI.label2
                ).cursor(.pointingHand)
                Button("None") { picked = [] }.buttonStyle(.plain).font(UI.small).foregroundStyle(UI.label2).cursor(
                    .pointingHand)
            }
            Text("Checked values become {{placeholders}}; their current values are the defaults.")
                .font(.system(size: 10.5)).foregroundStyle(UI.faint)
            if candidates.isEmpty {
                Text("This scene has no simple values to expose.").font(UI.small).foregroundStyle(UI.faint)
            }
            ForEach(layers, id: \.self) { layer in
                VStack(alignment: .leading, spacing: 2) {
                    Text(layer).font(UI.mono).foregroundStyle(UI.text)
                    ForEach(candidates.filter { $0.layer == layer }) { c in row(c) }
                }
            }
        }
    }

    private func row(_ c: LibraryModel.ParamCandidate) -> some View {
        Toggle(
            isOn: Binding(
                get: { picked.contains(c.id) },
                set: { on in if on { picked.insert(c.id) } else { picked.remove(c.id) } })
        ) {
            HStack(spacing: 8) {
                Text(c.prop + (c.path.count > 1 && c.kind != "symbol" ? " (end)" : "")).font(UI.small).foregroundStyle(
                    UI.label2
                ).frame(width: 90, alignment: .leading)
                Text(LibraryModel.text(c.current, kind: c.kind).replacingOccurrences(of: "\n", with: " ⏎ "))
                    .font(UI.monoSmall).foregroundStyle(UI.dim).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Text("{{\(c.paramName)}}").font(UI.monoSmall).foregroundStyle(UI.faint).lineLimit(1)
            }
        }
        .toggleStyle(.checkbox).padding(.leading, 4).frame(height: 22)
    }
}
