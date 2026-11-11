import ArclightCore
import SwiftUI

/// Form generated from `Template.params`: text, number, color, symbol and JSON fields.
struct TemplateForm: View {
    let template: Template
    @Binding var values: [String: String]
    var invalid: Set<String> = []
    var projectURL: URL?
    var theme: [String: JSONValue] = Project.defaultTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if template.params.isEmpty {
                Text("No parameters").font(UI.small).foregroundStyle(UI.faint)
            }
            ForEach(template.params, id: \.name) { p in
                ParamField(
                    param: p, text: Binding(get: { values[p.name] ?? "" }, set: { values[p.name] = $0 }),
                    invalid: invalid.contains(p.name), projectURL: projectURL, theme: theme)
            }
        }
    }

    static func defaults(_ t: Template) -> [String: String] {
        Dictionary(uniqueKeysWithValues: t.params.map { ($0.name, LibraryModel.text($0.default, kind: $0.kind)) })
    }

    /// Values that differ from the defaults, plus the names of fields that don't parse.
    static func parse(_ t: Template, _ values: [String: String]) -> (values: [String: JSONValue], invalid: Set<String>)
    {
        var out: [String: JSONValue] = [:], bad = Set<String>()
        for p in t.params {
            guard let txt = values[p.name], txt != LibraryModel.text(p.default, kind: p.kind) else { continue }
            if let v = LibraryModel.value(txt, kind: p.kind) { out[p.name] = v } else { bad.insert(p.name) }
        }
        return (out, bad)
    }
}

private struct ParamField: View {
    let param: Template.Param
    @Binding var text: String
    var invalid = false
    var projectURL: URL?
    var theme: [String: JSONValue]
    @State private var browsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(param.label ?? param.name.prefix(1).uppercased() + param.name.dropFirst()).font(UI.small)
                    .foregroundStyle(UI.label2)
                Spacer()
                Text(param.kind ?? "text").font(UI.monoSmall).foregroundStyle(UI.faint)
            }
            control.overlay(
                RoundedRectangle(cornerRadius: 6).stroke(invalid ? Color.red.opacity(0.8) : .clear, lineWidth: 1))
            if let d = param.doc {
                Text(d).font(.system(size: 10.5)).foregroundStyle(UI.faint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch param.kind {
        case "number":
            FieldBox { TextField("0", text: $text) }
        case "color":
            HStack(spacing: 6) {
                ColorPicker("", selection: colorBinding, supportsOpacity: true).labelsHidden().frame(width: 34)
                FieldBox { TextField("#FFFFFF or $token", text: $text) }
            }
        case "symbol":
            Button {
                browsing = true
            } label: {
                HStack(spacing: 6) {
                    SymbolThumb(id: text, project: projectURL).frame(width: 18, height: 18)
                    Text(text.isEmpty ? "Choose…" : text).font(UI.mono).foregroundStyle(UI.text).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "square.grid.2x2").font(.system(size: 9.5)).foregroundStyle(UI.dim)
                }
                .fieldChrome(height: 26)
            }
            .buttonStyle(.plain).cursor(.pointingHand)
            .popover(isPresented: $browsing, arrowEdge: .leading) {
                SymbolBrowser(project: projectURL, selected: text) {
                    text = $0; browsing = false
                }
            }
        case "json":
            FieldBox { TextField("JSON", text: $text, axis: .vertical).lineLimit(1...6).padding(.vertical, 5) }
        default:
            FieldBox {
                TextField("", text: $text, axis: .vertical).font(UI.font).lineLimit(1...5).padding(.vertical, 5)
            }
        }
    }

    /// Swatch colour (theme tokens resolved); picking writes a hex value.
    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                let v: JSONValue =
                    text.hasPrefix("$") ? (theme[String(text.dropFirst())] ?? .string(text)) : .string(text)
                return Color(arclight: v) ?? .white
            }, set: { text = $0.hex })
    }
}
