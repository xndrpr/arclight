import SwiftUI

/// The viewer's top bar: zoom, guides and align on the left, performance / viewer-only / cinema on the right.
/// Both groups sit `inset` from the viewport edges. When the viewport is narrow the layout steps down
/// (align buttons fold into a menu, then the right group folds into "…") instead of overflowing or overlapping.
struct ViewerChrome: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var vp: ViewportState
    static let inset: CGFloat = 8

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(align: .inline, right: .full)
            row(align: .menu, right: .full)
            row(align: .menu, right: .menu)
        }
        .padding(Self.inset)
    }

    private func row(align: CanvasToolbar.AlignStyle, right: ViewerToolbar.Style) -> some View {
        HStack(alignment: .top, spacing: 8) {
            CanvasToolbar(doc: doc, vp: vp, align: align)
            Spacer(minLength: 0)
            ViewerToolbar(doc: doc, style: right)
        }
    }
}

/// Floating pill behind a toolbar group.
private struct ToolbarPill: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(3)
            .background(RoundedRectangle(cornerRadius: 7).fill(UI.panel.opacity(0.92)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(UI.border))
            .fixedSize()
    }
}

/// Viewer toolbar, top-left: zoom, guides and (with a selection) align & distribute.
private struct CanvasToolbar: View {
    enum AlignStyle { case inline, menu }
    @ObservedObject var doc: EditorDocument
    @ObservedObject var vp: ViewportState
    var align: AlignStyle = .inline

    var body: some View {
        HStack(spacing: 2) {
            ZoomControl(vp: vp)
            Hairline(vertical: true).frame(height: 16).padding(.horizontal, 3)
            GuidesMenu(doc: doc)
            let n = doc.selectedLayerIds.count
            if n >= 1 {
                Hairline(vertical: true).frame(height: 16).padding(.horizontal, 3)
                if align == .inline { AlignButtons(doc: doc, count: n) } else { AlignMenu(doc: doc, count: n) }
            }
        }
        .modifier(ToolbarPill())
    }
}

/// "62%" label (double-click = Fit) and a menu of zoom presets.
private struct ZoomControl: View {
    @ObservedObject var vp: ViewportState

    var body: some View {
        Menu {
            Button("Fit  (double-click)") { withMotion(UI.snappy) { vp.fit() } }
            Divider()
            ForEach(ViewZoom.presets, id: \.self) { z in Button(ViewZoom.label(z)) { vp.setScale(z) } }
            Divider()
            Button("Zoom in") { vp.zoom(by: 1.25, at: nil) }
            Button("Zoom out") { vp.zoom(by: 0.8, at: nil) }
        } label: {
            HStack(spacing: 3) {
                Text(vp.isFit ? "Fit" : ViewZoom.label(vp.scale)).font(UI.monoSmall).foregroundStyle(UI.text)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)).foregroundStyle(UI.dim)
            }
            .frame(minWidth: 44, minHeight: 22).barHit()
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .simultaneousGesture(TapGesture(count: 2).onEnded { withMotion(UI.snappy) { vp.fit() } })
        .help("Viewer zoom — pinch or ⌘-scroll at the pointer, scroll or Space-drag to pan, double-click for Fit")
        .cursor(.pointingHand)
    }
}

private struct GuidesMenu: View {
    /// Snapping is the document's one setting (`doc.snapping`, Settings ▸ Snapping, N), shared with the timeline.
    @ObservedObject var doc: EditorDocument
    @AppStorage(Pref.rulers) private var rulers = false
    @AppStorage(Pref.centerLines) private var center = false
    @AppStorage(Pref.safeAreas) private var safe = false
    @AppStorage(Pref.thirds) private var thirds = false

    var body: some View {
        Menu {
            Toggle("Rulers", isOn: $rulers)
            Toggle("Centre lines", isOn: $center)
            Toggle("Safe areas (90% / 80%)", isOn: $safe)
            Toggle("Rule of thirds", isOn: $thirds)
            Divider()
            Toggle("Snapping (hold ⌘ to bypass)", isOn: $doc.snapping)
        } label: {
            Image(systemName: "grid").font(.system(size: 11, weight: .medium))
                .foregroundStyle(rulers || center || safe || thirds ? UI.accent : UI.dim)
                .frame(width: 24, height: 22).barHit()
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Guides: rulers, centre lines, safe areas, rule of thirds · snapping")
        .cursor(.pointingHand)
    }
}

private func alignModes(_ count: Int) -> [AlignMode] { AlignMode.allCases.filter { !$0.isDistribute || count >= 3 } }
private func alignHelp(_ m: AlignMode, _ count: Int) -> String {
    m.title + (count == 1 && !m.isDistribute ? " (to canvas)" : "")
}

private struct AlignButtons: View {
    @ObservedObject var doc: EditorDocument
    let count: Int

    var body: some View {
        ForEach(alignModes(count), id: \.self) { m in
            IconButton(symbol: m.symbol, help: alignHelp(m, count)) { doc.align(m) }
        }
    }
}

/// Align & distribute folded into one menu (narrow viewers).
private struct AlignMenu: View {
    @ObservedObject var doc: EditorDocument
    let count: Int

    var body: some View {
        Menu {
            ForEach(alignModes(count), id: \.self) { m in
                Button {
                    doc.align(m)
                } label: {
                    Label(alignHelp(m, count), systemImage: m.symbol)
                }
            }
        } label: {
            Image(systemName: "align.horizontal.left").font(.system(size: 11, weight: .medium)).foregroundStyle(UI.dim)
                .frame(width: 24, height: 22).barHit()
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(count == 1 ? "Align to the canvas" : "Align and distribute the selected layers")
        .cursor(.pointingHand)
    }
}

/// Viewer toolbar, top-right: performance mode, viewer only, cinema. Folds into "…" when narrow.
private struct ViewerToolbar: View {
    enum Style { case full, menu }
    @ObservedObject var doc: EditorDocument
    var style: Style = .full

    private static let perfHelp = "Performance mode — half-resolution preview for heavy scenes (⇧⌘P)"

    var body: some View {
        HStack(spacing: 2) {
            if let b = doc.busy {
                ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 18, height: 18).help(b)
                if style == .full { Text(b).font(UI.small).foregroundStyle(UI.dim).lineLimit(1).padding(.trailing, 6) }
            }
            if style == .full {
                IconButton(symbol: "bolt.fill", help: Self.perfHelp, active: doc.performance) {
                    doc.performance.toggle()
                }
                IconButton(
                    symbol: doc.viewerOnly ? "rectangle.split.3x1" : "rectangle",
                    help: doc.viewerOnly ? "Show the panels again (⌘F)" : "Viewer only — hide the panels (⌘F)",
                    active: doc.viewerOnly
                ) { doc.viewerOnly.toggle() }
                IconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Cinema viewer — full screen (P)") {
                    doc.onCinemaChange?(true)
                }
            } else {
                Menu {
                    Toggle("Performance Mode (⇧⌘P)", isOn: $doc.performance)
                    Toggle("Viewer Only (⌘F)", isOn: $doc.viewerOnly)
                    Button("Cinema Viewer (P)") { doc.onCinemaChange?(true) }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(doc.performance || doc.viewerOnly ? UI.accent : UI.dim)
                        .frame(width: 24, height: 22).barHit()
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Viewer: performance mode, viewer only, cinema")
                .cursor(.pointingHand)
            }
        }
        .modifier(ToolbarPill())
    }
}
