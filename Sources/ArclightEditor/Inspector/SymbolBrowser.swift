import ArclightCore
import SwiftUI

/// Cached symbol outlines for previews.
enum SymbolPreviewCache {
    nonisolated(unsafe) private static var paths: [String: (CGPath, Bool)?] = [:]

    static func path(_ id: String, project: URL?) -> (CGPath, Bool)? {
        let key = (project?.path ?? "") + "|" + id
        if let c = paths[key] { return c }
        let p = Symbols.previewPath(id, project: project).map { ($0, Symbols.previewUsesEvenOdd(id, project: project)) }
        paths[key] = .some(p)
        return p
    }
}

/// A symbol drawn to fit its box (white silhouette).
struct SymbolThumb: View {
    let id: String
    let project: URL?
    var color: Color = UI.text

    var body: some View {
        Canvas { ctx, size in
            guard let (cg, evenOdd) = SymbolPreviewCache.path(id, project: project) else {
                ctx.stroke(
                    Path(CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)), with: .color(UI.faint), lineWidth: 1)
                return
            }
            let b = cg.boundingBoxOfPath
            guard b.width > 0, b.height > 0 else { return }
            let s = min(size.width / b.width, size.height / b.height) * 0.86
            // Symbols are y-up; flip into the view.
            var t = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
                .scaledBy(x: s, y: -s).translatedBy(x: -b.midX, y: -b.midY)
            if let p = cg.copy(using: &t) {
                ctx.fill(Path(p), with: .color(color), style: FillStyle(eoFill: evenOdd))
            }
        }
    }
}

/// Grid of every available symbol (built-in, user library, project), grouped by pack, with search.
struct SymbolBrowser: View {
    let project: URL?
    let selected: String?
    let pick: (String) -> Void
    @State private var query = ""

    var body: some View {
        let all = Symbols.all(project: project).filter {
            query.isEmpty || $0.id.lowercased().contains(query.lowercased())
                || $0.name.lowercased().contains(query.lowercased())
        }
        let packs = all.map(\.pack).uniqued(by: { $0 })
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Symbols").font(.system(size: 12, weight: .semibold)).foregroundStyle(UI.text)
                Spacer()
                Text("\(all.count)").font(UI.monoSmall).foregroundStyle(UI.faint)
            }
            FieldBox { TextField("Search symbols", text: $query) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(packs, id: \.self) { pack in
                        SmallCapsLabel(pack)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 58, maximum: 70), spacing: 6)], spacing: 6) {
                            ForEach(all.filter { $0.pack == pack }, id: \.id) { s in cell(s) }
                        }
                    }
                }
            }
            .frame(height: 300)
            Text(
                "Add packs to ~/Library/Application Support/Arclight/library/symbols or the project's symbols/ folder."
            )
            .font(UI.small).foregroundStyle(UI.faint).fixedSize(horizontal: false, vertical: true)
        }
        .popoverChrome(width: 340)
    }

    private func cell(_ s: Symbols.Info) -> some View {
        let on = s.id == selected
        return Button {
            pick(s.id)
        } label: {
            VStack(spacing: 3) {
                SymbolThumb(id: s.id, project: project).frame(width: 34, height: 34)
                Text(s.name).font(.system(size: 9.5)).foregroundStyle(UI.label2).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? UI.selected : UI.field))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? UI.accent : UI.fieldBorder, lineWidth: on ? 1.5 : 1))
            .hitArea()
        }
        .buttonStyle(.plain).cursor(.pointingHand).help(s.id)
    }
}

/// Shows the chosen symbol; click to browse.
struct SymbolField: View {
    @ObservedObject var doc: EditorDocument
    let value: String?
    let commit: (String) -> Void
    @State private var open = false

    var body: some View {
        Button {
            open = true
        } label: {
            HStack(spacing: 6) {
                if let value { SymbolThumb(id: value, project: doc.url).frame(width: 18, height: 18) }
                Text(value ?? "Choose…").font(UI.mono).foregroundStyle(value == nil ? UI.dim : UI.text).lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "square.grid.2x2").font(.system(size: 9.5)).foregroundStyle(UI.dim)
            }
            .fieldChrome(height: 26)
        }
        .buttonStyle(.plain).cursor(.pointingHand)
        .popover(isPresented: $open, arrowEdge: .leading) {
            SymbolBrowser(project: doc.url, selected: value) {
                commit($0); open = false
            }
        }
    }
}
