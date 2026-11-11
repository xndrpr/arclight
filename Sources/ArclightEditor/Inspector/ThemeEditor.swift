import AppKit
import ArclightCore
import SwiftUI

/// Nothing-selected inspector section: the project's theme tokens.
struct ThemeEditor: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        CollapsibleSection(title: "Theme tokens", trailing: AnyView(count)) {
            VStack(alignment: .leading, spacing: 10) {
                ThemeTokenList(doc: doc)
                Text("Tokens like $fg restyle every layer and scene that uses them. An AI agent can set them too.")
                    .font(UI.small).foregroundStyle(UI.faint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var count: some View {
        Text("\(doc.project.theme.count)").font(UI.monoSmall).foregroundStyle(UI.faint).padding(.trailing, 4)
    }
}

/// Editable list of theme tokens, grouped into colours, fonts and other values, with an "add token" row.
/// Used by the scene inspector and the theme popover (callers add the header and insets).
/// Every edit is undoable (`setThemeToken`).
struct ThemeTokenList: View {
    @ObservedObject var doc: EditorDocument
    @State private var newKey = ""
    @State private var addError: String?

    private enum Kind { case color, font, other }

    private func kind(_ k: String, _ v: JSONValue) -> Kind {
        if v.string != nil, RGBA.parse(v) != nil { return .color }
        if ThemePresets.fontKeys.contains(k) { return .font }
        if let s = v.string, !s.hasPrefix("$"), NSFont(name: s, size: 12) != nil { return .font }
        return .other
    }

    var body: some View {
        let theme = doc.project.theme
        let keys = sortedKeys(theme)
        let groups: [(String, Kind)] = [("Colours", .color), ("Fonts", .font), ("Other", .other)]
        VStack(alignment: .leading, spacing: UI.rowSpacing) {
            ForEach(groups, id: \.0) { name, kd in
                let ks = keys.filter { kind($0, theme[$0]!) == kd }
                if !ks.isEmpty {
                    Text(name).font(UI.small).foregroundStyle(UI.dim).frame(height: 18)
                    ForEach(ks, id: \.self) { k in row(k, theme[k]!, kd) }
                }
            }
            if theme.isEmpty {
                Text("No tokens yet. Pick a preset, or add one below.").font(UI.small).foregroundStyle(UI.faint)
            }
            addRow.padding(.top, 4)
        }
    }

    /// Standard tokens first (in their usual order), then the rest alphabetically.
    private func sortedKeys(_ t: [String: JSONValue]) -> [String] {
        let std = ThemePresets.standardKeys.filter { t[$0] != nil }
        return std + t.keys.filter { !ThemePresets.standardKeys.contains($0) }.sorted()
    }

    private func row(_ k: String, _ v: JSONValue, _ kd: Kind) -> some View {
        HStack(spacing: 6) {
            TokenLabel(key: k)
            Group {
                switch kd {
                case .color:
                    ColorField(doc: doc, value: v.string ?? "", tokens: false) { doc.setThemeToken(k, .string($0)) }
                case .font:
                    ThemeFontField(doc: doc, value: v.string ?? "") { doc.setThemeToken(k, .string($0)) }
                case .other:
                    TextCommitField(text: v.string ?? v.compactString, mono: true) { str in
                        doc.setThemeToken(
                            k, JSONValue.parse(str).flatMap { $0.string == nil ? $0 : nil } ?? .string(str))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            IconButton(symbol: "minus", help: "Remove $\(k) (layers using it fall back to defaults)") {
                doc.setThemeToken(k, nil)
            }
        }
        .id(k)
    }

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                FieldBox {
                    TextField("New token name", text: $newKey).font(UI.font).onSubmit(add)
                }
                .frame(minWidth: 0, maxWidth: .infinity)
                Button("Add", action: add).buttonStyle(PillButtonStyle()).fixedSize()
                    .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty).opacity(
                        newKey.trimmingCharacters(in: .whitespaces).isEmpty ? 0.45 : 1
                    )
                    .help("Adds a colour token; type a font name into its value to make it a font")
            }
            if let addError { Text(addError).font(UI.small).foregroundStyle(UI.danger) }
        }
    }

    private func add() {
        let k = newKey.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        guard !k.isEmpty else { return }
        guard k.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            addError = "Use letters, digits, - or _ only"; return
        }
        guard doc.project.theme[k] == nil else { addError = "$\(k) already exists"; return }
        addError = nil
        doc.setThemeToken(k, "#FFFFFF")
        newKey = ""
    }
}

/// `$key` with its plain-language meaning underneath (for the standard tokens).
private struct TokenLabel: View {
    let key: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("$" + key).font(UI.mono).foregroundStyle(UI.label2).lineLimit(1).truncationMode(.tail)
            if let d = ThemePresets.describe(key) {
                Text(d).font(.system(size: 9.5)).foregroundStyle(UI.faint).lineLimit(1).truncationMode(.tail)
            }
        }
        .frame(width: UI.labelWidth, alignment: .leading)
        .help("$" + key + (ThemePresets.describe(key).map { " — " + $0 } ?? ""))
    }
}

/// A font token's value: shown in its own face; click to pick from installed fonts.
private struct ThemeFontField: View {
    @ObservedObject var doc: EditorDocument
    let value: String
    let commit: (String) -> Void
    @State private var open = false

    var body: some View {
        let missing = NSFont(name: value, size: 12) == nil
        FieldButton(spacing: 6, border: missing ? UI.warning.opacity(0.6) : UI.fieldBorder, action: { open = true }) {
            Text(missing ? value : FontCatalog.displayName(value)).font(.custom(value, size: 12.5))
                .foregroundStyle(missing ? UI.warning : UI.text).lineLimit(1).truncationMode(.tail)
        }
        .help(missing ? "\(value) is not installed on this Mac — pick another font" : value)
        .popover(isPresented: $open, arrowEdge: .leading) {
            FontPicker(doc: doc, current: value, sample: "Aa 45%", showTokens: false) {
                commit($0); open = false
            }
        }
    }
}
