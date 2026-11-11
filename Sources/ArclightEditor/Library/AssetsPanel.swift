import ArclightCore
import SwiftUI

/// Left sidebar "Assets" tab: the project's images, audio, fonts, all symbols and saved templates.
struct AssetsPanel: View {
    @ObservedObject var doc: EditorDocument
    @AppStorage(Pref.assetsCollapsed) private var collapsedRaw = ""

    var body: some View {
        let _ = doc.libraryVersion
        VStack(spacing: 0) {
            SectionHeader(
                title: "Assets",
                trailing: AnyView(
                    IconButton(symbol: "square.and.arrow.down", help: "Import files…") { doc.importAssetsWithPanel() }))
            Hairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section("Images", count: LibraryModel.files(.image, in: doc.url).count) { ImagesSection(doc: doc) }
                    section("Audio", count: LibraryModel.files(.audio, in: doc.url).count) { AudioSection(doc: doc) }
                    section("Fonts", count: LibraryModel.files(.font, in: doc.url).count) { FontsSection(doc: doc) }
                    section("Symbols", count: Symbols.all(project: doc.url).count) { SymbolsSection(doc: doc) }
                    section("Templates", count: LibraryModel.templateFiles(project: doc.url).count) {
                        TemplatesSection(doc: doc)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .background(UI.panel)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { u, _ in
                    if let u { DispatchQueue.main.async { doc.importAssets([u]) } }
                }
            }
            return true
        }
    }

    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

    @ViewBuilder private func section<C: View>(_ title: String, count: Int, @ViewBuilder content: () -> C) -> some View
    {
        let open = !collapsed.contains(title)
        Button {
            var c = collapsed
            if open { c.insert(title) } else { c.remove(title) }
            collapsedRaw = c.sorted().joined(separator: ",")
        } label: {
            HStack(spacing: 6) {
                Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(UI.faint).frame(width: 10)
                SmallCapsLabel(title)
                Spacer()
                Text("\(count)").font(UI.monoSmall).foregroundStyle(UI.faint)
            }
            .padding(.horizontal, 12).frame(height: 30).hitArea()
        }
        .buttonStyle(.plain).cursor(.pointingHand)
        if open { content().padding(.horizontal, 10).padding(.bottom, 10) }
        Hairline()
    }
}
