import AppKit
import ArclightCore
import SwiftUI

/// Installed fonts (PostScript names) and which of them cover Cyrillic, computed once.
enum FontCatalog {
    static let all: [String] = NSFontManager.shared.availableFonts.filter { !$0.hasPrefix(".") }.sorted()
    nonisolated(unsafe) private static var cyrillicCache: [String: Bool] = [:]

    static func coversCyrillic(_ name: String) -> Bool {
        if let c = cyrillicCache[name] { return c }
        let set = NSFont(name: name, size: 12)?.coveredCharacterSet
        let ok = set.map { cs in "\u{0416}\u{0436}\u{044F}".unicodeScalars.allSatisfy { cs.contains($0) } } ?? false
        cyrillicCache[name] = ok
        return ok
    }

    static func displayName(_ name: String) -> String { NSFont(name: name, size: 12)?.displayName ?? name }
}

/// Font picker: the current font in its own face; the popover lists theme font tokens first, then every
/// installed font with a live preview of the layer's text, search and a Cyrillic filter.
struct FontField: View {
    @ObservedObject var doc: EditorDocument
    let slot: Slot
    @State private var open = false

    private var value: String { slot.shown?.string ?? "" }
    private var resolved: String { doc.renderer.evaluator.resolve(.string(value)).string ?? value }

    var body: some View {
        FieldButton(spacing: 6, height: 26, action: { open = true }) {
            if value.hasPrefix("$") {
                Text(value).font(UI.mono).foregroundStyle(UI.text).lineLimit(1).layoutPriority(1)
            } else {
                Text(value.isEmpty ? "Choose font" : FontCatalog.displayName(value)).font(.custom(resolved, size: 12.5))
                    .foregroundStyle(value.isEmpty ? UI.dim : UI.text).lineLimit(1)
            }
        }
        .help(value.hasPrefix("$") ? "Theme font \(value) = \(resolved). Click to choose another font" : slot.field.doc)
        .popover(isPresented: $open, arrowEdge: .leading) {
            FontPicker(doc: doc, current: value, sample: sample) { doc.write(slot, .string($0)) }
        }
    }

    /// Preview text: the layer's own text, else "Aa".
    private var sample: String {
        guard case .node(let id) = slot.host, let t = doc.scene.node(id)?.props["text"]?.rawValue(at: 0)?.string else {
            return "Aa"
        }
        let s = t.replacingOccurrences(of: "{v}", with: "45").replacingOccurrences(of: "\n", with: " ")
        return s.isEmpty ? "Aa" : String(s.prefix(28))
    }
}

struct FontPicker: View {
    @ObservedObject var doc: EditorDocument
    let current: String
    let sample: String
    /// List the project's font tokens first (off when picking a token's own value).
    var showTokens = true
    let pick: (String) -> Void
    @State private var query = ""
    @State private var cyrillic = false

    private var tokens: [(String, String)] {
        doc.project.theme.compactMap { k, v in
            guard let s = v.string, NSFont(name: s, size: 12) != nil else { return nil }
            return ("$" + k, s)
        }.sorted { $0.0 < $1.0 }
    }

    private var fonts: [String] {
        let q = query.lowercased()
        return FontCatalog.all.filter { f in
            (q.isEmpty || f.lowercased().contains(q) || FontCatalog.displayName(f).lowercased().contains(q))
                && (!cyrillic || FontCatalog.coversCyrillic(f))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                FieldBox { TextField("Search fonts", text: $query) }
                Toggle("Cyrillic", isOn: $cyrillic).toggleStyle(.checkbox).font(UI.small).foregroundStyle(UI.label2)
                    .fixedSize()
                    .help("Only fonts that can show Russian text")
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if showTokens && !tokens.isEmpty && query.isEmpty {
                        header("Theme")
                        ForEach(tokens, id: \.0) { t in row(id: t.0, face: t.1, caption: t.0 + " · " + t.1) }
                        header("All fonts")
                    }
                    ForEach(fonts, id: \.self) { f in row(id: f, face: f, caption: f) }
                    if fonts.isEmpty {
                        Text("No installed font matches “\(query)”.").font(UI.small).foregroundStyle(UI.faint).padding(
                            .vertical, 12)
                    }
                }
            }
            .frame(width: 360, height: 380)
        }
        .popoverChrome()
    }

    private func header(_ s: String) -> some View {
        SmallCapsLabel(s).padding(.top, 8).padding(.bottom, 4)
    }

    private func row(id: String, face: String, caption: String) -> some View {
        let on = id == current
        return Button {
            pick(id)
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(sample).font(.custom(face, size: 17)).foregroundStyle(UI.text).lineLimit(1)
                Text(caption).font(UI.monoSmall).foregroundStyle(on ? UI.text : UI.faint).lineLimit(1)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? UI.selected : .clear))
            .hitArea()
        }
        .buttonStyle(.plain).cursor(.pointingHand)
    }
}
