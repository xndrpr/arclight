import AppKit
import ArclightCore
import SwiftUI

/// "+ Layer ▸ Symbol ▸ pack ▸ symbol": adds one symbol as its own layer. Also offers a crowd of it (a repeater) and,
/// when a repeater is selected, adding it to that repeater's items.
struct SymbolsMenu: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        let all = Symbols.all(project: doc.url)
        let packs = all.uniqued(by: \.pack).map(\.pack)
        Menu("Symbol") {
            packMenus(all, packs) { doc.addSymbolLayer($0) }
            Divider()
            Menu("Crowd of Symbol (Repeater, 3D)") { packMenus(all, packs) { doc.addRepeater(symbol: $0) } }
            if let r = doc.selectedRepeater {
                Menu("Add to \(r)") { packMenus(all, packs) { doc.useSymbolInSelectedRepeater($0) } }
            }
        }
    }

    @ViewBuilder private func packMenus(
        _ all: [Symbols.Info], _ packs: [String], _ action: @escaping (String) -> Void
    ) -> some View {
        ForEach(packs, id: \.self) { pack in
            Menu(pack.capitalized) {
                ForEach(all.filter { $0.pack == pack }, id: \.id) { s in
                    Button {
                        action(s.id)
                    } label: {
                        if let img = SymbolMenuIcon.image(s.id, project: doc.url) { Image(nsImage: img) }
                        Text(s.name)
                    }
                }
            }
        }
    }
}

/// Small template images of symbol outlines for menus.
@MainActor private enum SymbolMenuIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(_ id: String, project: URL?, size: CGFloat = 16) -> NSImage? {
        let key = (project?.path ?? "") + "|" + id
        if let c = cache[key] { return c }
        guard let (cg, evenOdd) = SymbolPreviewCache.path(id, project: project) else { return nil }
        let b = cg.boundingBoxOfPath
        guard b.width > 0, b.height > 0 else { return nil }
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let s = min(r.width / b.width, r.height / b.height) * 0.9
            // Preview paths are y-up (SymbolThumb flips them), which matches AppKit's unflipped context.
            ctx.translateBy(x: r.midX, y: r.midY)
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -b.midX, y: -b.midY)
            ctx.addPath(cg)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fillPath(using: evenOdd ? .evenOdd : .winding)
            return true
        }
        img.isTemplate = true
        cache[key] = img
        return img
    }
}
