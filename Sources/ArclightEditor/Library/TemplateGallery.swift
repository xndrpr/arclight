import AppKit
import ArclightCore
import SwiftUI

/// Gallery of templates with previews and a category filter; the selected template's parameters are edited in a
/// generated form with a live preview. Creates a new scene, or inserts the layers into the current scene.
struct TemplateGallery: View {
    enum Mode { case newScene, insert }
    @ObservedObject var doc: EditorDocument
    let mode: Mode
    let close: () -> Void
    /// Template selected when the gallery opens (snapshots; defaults to the first).
    var initial: String?
    @State private var category: String?
    @State private var selected: String?
    @State private var values: [String: String] = [:]

    var body: some View {
        let all = Templates.all(project: doc.url)
        let shown = all.filter { category == nil || ($0.category ?? "Other") == category }
        let current = all.first { $0.id == selected } ?? shown.first
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header(all)
                Hairline()
                ScrollView {
                    TemplateGrid(
                        templates: shown, selected: current?.id, canvas: doc.projectCanvas, project: doc.project,
                        projectURL: doc.url
                    ) { t in
                        select(t)
                    }
                    .padding(16)
                }
            }
            .frame(minWidth: 520, maxWidth: .infinity)
            Hairline(vertical: true)
            if let t = current {
                TemplateDetail(doc: doc, template: t, values: $values, mode: mode, close: close)
                    .frame(width: 360).id(t.id)
            } else {
                Text("No templates").font(UI.font).foregroundStyle(UI.faint).frame(width: 360).frame(
                    maxHeight: .infinity)
            }
        }
        .background(UI.bg)
        .onAppear {
            if selected == nil, let f = all.first(where: { $0.id == initial }) ?? shown.first { select(f) }
        }
    }

    private func select(_ t: Template) {
        guard selected != t.id else { return }
        selected = t.id
        values = TemplateForm.defaults(t)
    }

    private func header(_ all: [Template]) -> some View {
        let cats = all.map { $0.category ?? "Other" }.uniqued { $0 }
        return HStack(spacing: 6) {
            Text(mode == .newScene ? "New scene from template" : "Insert template").font(
                .system(size: 14, weight: .semibold)
            ).foregroundStyle(UI.text)
            Spacer()
            Chip(title: "All", on: category == nil) { category = nil }
            ForEach(cats, id: \.self) { c in Chip(title: c, on: category == c) { category = c } }
        }
        .padding(.horizontal, 16).frame(height: 52)
    }
}

/// Small toggle pill used for filters.
private struct Chip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? UI.onAccent : UI.label2)
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(on ? UI.accent : UI.raised))
                .overlay(Capsule().stroke(on ? .clear : UI.border, lineWidth: 1))
                .hitArea()
        }
        .buttonStyle(.plain).cursor(.pointingHand)
    }
}

/// Grid of template cards (optionally with a leading "Blank" card).
struct TemplateGrid: View {
    let templates: [Template]
    let selected: String?
    let canvas: (Int, Int)
    var project: Project?
    var projectURL: URL?
    var blank = false
    var minWidth: CGFloat = 190
    let pick: (Template) -> Void
    var pickBlank: () -> Void = {}

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 12)], spacing: 14) {
            if blank { BlankCard(canvas: canvas, on: selected == nil, action: pickBlank) }
            ForEach(templates, id: \.id) { t in
                TemplateCard(
                    template: t, canvas: canvas, project: project, projectURL: projectURL, on: selected == t.id
                ) { pick(t) }
            }
        }
    }
}

private struct TemplateCard: View {
    let template: Template
    let canvas: (Int, Int)
    var project: Project?
    var projectURL: URL?
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                TemplateThumb(template: template, canvas: canvas, project: project, projectURL: projectURL)
                    .frame(maxWidth: .infinity)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4).stroke(
                            on ? UI.accent : (hover ? UI.fieldBorder : .clear), lineWidth: on ? 2 : 1)
                    )
                    .scaleEffect(hover && !on && !Motion.reduce ? 1.015 : 1)
                HStack(spacing: 6) {
                    Text(template.name).font(.system(size: 12, weight: .medium)).foregroundStyle(UI.text).lineLimit(1)
                    Spacer(minLength: 0)
                    if let c = template.category {
                        Text(c.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(
                            UI.faint)
                    }
                }
            }
            .hitArea()
        }
        .buttonStyle(.plain).onHover { h in withMotion(UI.fade) { hover = h } }.cursor(.pointingHand).help(
            template.description ?? template.name)
    }
}

private struct BlankCard: View {
    let canvas: (Int, Int)
    let on: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4).fill(UI.field)
                    .aspectRatio(CGFloat(canvas.0) / CGFloat(max(canvas.1, 1)), contentMode: .fit)
                    .overlay(Image(systemName: "plus").font(.system(size: 18, weight: .light)).foregroundStyle(UI.dim))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4).stroke(
                            on ? UI.accent : (hover ? UI.fieldBorder : UI.border), lineWidth: on ? 2 : 1))
                Text("Blank").font(.system(size: 12, weight: .medium)).foregroundStyle(UI.text)
            }
            .hitArea()
        }
        .buttonStyle(.plain).onHover { h in withMotion(UI.fade) { hover = h } }.cursor(.pointingHand).help(
            "Start from an empty scene")
    }
}

/// Right pane: big live preview, description, parameter form, actions.
private struct TemplateDetail: View {
    @ObservedObject var doc: EditorDocument
    let template: Template
    @Binding var values: [String: String]
    let mode: TemplateGallery.Mode
    let close: () -> Void

    var body: some View {
        let parsed = TemplateForm.parse(template, values)
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    TemplateThumb(
                        template: template, params: parsed.values, canvas: doc.projectCanvas, project: doc.project,
                        projectURL: doc.url, width: 720, debounce: 250_000_000
                    )
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(template.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(UI.text)
                        if let d = template.description {
                            Text(d).font(UI.small).foregroundStyle(UI.dim).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    TemplateForm(
                        template: template, values: $values, invalid: parsed.invalid, projectURL: doc.url,
                        theme: doc.project.theme)
                }
                .padding(16)
            }
            Hairline()
            SheetFooter(
                cancel: close, confirmTitle: mode == .newScene ? "Create scene" : "Insert layers",
                confirmDisabled: !parsed.invalid.isEmpty,
                confirm: {
                    close()
                    if mode == .newScene {
                        doc.newScene(from: template, params: parsed.values)
                    } else {
                        doc.insertTemplate(template, params: parsed.values)
                    }
                }
            ) {
                Text(template.id).font(UI.monoSmall).foregroundStyle(UI.faint).lineLimit(1)
            }
        }
        .background(UI.panel)
    }
}
