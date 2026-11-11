import AppKit
import ArclightCore
import SwiftUI

/// Window layout: top bar · left sidebar | viewport + timeline | inspector, with the AI panel floating over the
/// viewport column (`FloatingAIPanel`). Sidebars and timeline are resizable; when the window is too narrow,
/// the sidebars give up width before the viewport does.
struct EditorView: View {
    @ObservedObject var doc: EditorDocument
    @AppStorage(Pref.leftWidth) private var leftW: Double = 210
    @AppStorage(Pref.rightWidth) private var rightW: Double = 360
    @AppStorage(Pref.timelineHeight) private var timelineH: Double = 280
    @State private var showExport = false
    @State private var showShortcuts = false
    /// Where the top-bar AI pill is (global), for the panel's open/close animation.
    @State private var pill: CGRect = .zero

    var body: some View {
        Group {
            if doc.cinema {
                ViewportView(doc: doc)
            } else if doc.viewerOnly {
                VStack(spacing: 0) {
                    TopBar(doc: doc, export: { showExport = true })
                    Hairline()
                    ViewportView(doc: doc)
                        .overlay { FloatingAIPanel(doc: doc, pill: pill) }
                    Hairline()
                    TransportBar(doc: doc).background(UI.panel)
                }
            } else {
                VStack(spacing: 0) {
                    TopBar(doc: doc, export: { showExport = true })
                    Hairline()
                    GeometryReader { g in panels(PanelWidths.fit(total: g.size.width, left: leftW, right: rightW)) }
                }
            }
        }
        // The top bar fills the title-bar row (see EditorWindowController): no safe-area gap above it.
        .ignoresSafeArea(.container, edges: .top)
        .onPreferenceChange(AIPillFrameKey.self) { pill = $0 }
        .background(UI.bg)
        .themedRoot()
        .sheet(isPresented: $showExport) { ExportSheet(doc: doc, isPresented: $showExport) }
        .sheet(isPresented: $showShortcuts) { ShortcutsSheet(isPresented: $showShortcuts) }
        .onReceive(NotificationCenter.default.publisher(for: .showExport)) { n in
            if (n.object as? EditorDocument) === doc { showExport = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showShortcuts)) { n in
            if (n.object as? EditorDocument) === doc { showShortcuts = true }
        }
    }

    private func panels(_ w: PanelWidths) -> some View {
        HStack(spacing: 0) {
            LeftSidebar(doc: doc).frame(width: w.left)
            SideResizeHandle(width: $leftW, range: 160...420, growsRight: true, defaultWidth: 210)
            VStack(spacing: 0) {
                ViewportView(doc: doc)
                ResizeHandle(height: $timelineH)
                TimelineView(doc: doc).frame(height: timelineH)
            }
            .frame(minWidth: PanelWidths.minCenter)
            .zIndex(1)
            SideResizeHandle(width: $rightW, range: 300...640, growsRight: false, defaultWidth: 360)
                .background(UI.panel).zIndex(11)
            // Above the viewport column, so the AI panel's shadow never draws over the inspector.
            InspectorView(doc: doc).frame(width: w.right).background(UI.panel)
                .clipped()
                .zIndex(2)
        }
        // Floats over everything below the top bar (sidebars, viewport, timeline, inspector); takes no layout space.
        .overlay { FloatingAIPanel(doc: doc, pill: pill) }
        .clipped()
    }
}

/// Side panel widths that fit the window: the left sidebar shrinks first, then the inspector, so the viewport
/// and transport keep at least `minCenter` points.
struct PanelWidths: Equatable {
    var left: Double, right: Double

    static let minCenter: Double = 440
    static let handle: Double = 7
    static let mins = (left: 160.0, right: 300.0)

    static func fit(total: Double, left: Double, right: Double) -> PanelWidths {
        var w = PanelWidths(left: left, right: right)
        var over = w.left + w.right + minCenter + 2 * handle - total
        func take(_ v: inout Double, _ min: Double) {
            guard over > 0, v > min else { return }
            let d = Swift.min(over, v - min)
            v -= d; over -= d
        }
        take(&w.left, mins.left)
        take(&w.right, mins.right)
        return w
    }
}
