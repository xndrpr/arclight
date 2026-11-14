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
                    if !doc.isThumbnail {
                        Hairline()
                        TransportBar(doc: doc).background(UI.panel)
                    }
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
        .sheet(isPresented: $showExport) {
            if doc.isThumbnail {
                StillExportSheet(doc: doc, isPresented: $showExport)
            } else {
                ExportSheet(doc: doc, isPresented: $showExport)
            }
        }
        .sheet(isPresented: $showShortcuts) { ShortcutsSheet(isPresented: $showShortcuts, thumbnail: doc.isThumbnail) }
        .onReceive(NotificationCenter.default.publisher(for: .showExport)) { n in
            if (n.object as? EditorDocument) === doc { showExport = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showShortcuts)) { n in
            if (n.object as? EditorDocument) === doc { showShortcuts = true }
        }
    }

    private func panels(_ w: PanelWidths) -> some View {
        HStack(spacing: 0) {
            // One structure in both workspaces (so the sidebar is updated, not rebuilt, on a switch): in Thumbnail the
            // open artboard's layers sit under the pages (Figma); in Motion that half is collapsed.
            VSplit(
                collapsed: !doc.isThumbnail || doc.isEmptyWorkspace,
                top: { LeftSidebar(doc: doc) },
                bottom: { if doc.isThumbnail && !doc.isEmptyWorkspace { ThumbnailLayersPanel(doc: doc).workspaceFade() } }
            )
            .frame(width: w.left)
            SideResizeHandle(width: $leftW, range: 160...420, growsRight: true, defaultWidth: 210)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    // Thumbnail tools in their own column (the Metal canvas would draw over a floating bar).
                    if doc.isThumbnail && !doc.isEmptyWorkspace {
                        ThumbnailToolBar(doc: doc).padding(.horizontal, 6).frame(maxHeight: .infinity).background(UI.bg)
                            .workspaceFade()
                        Hairline(vertical: true)
                    }
                    ViewportView(doc: doc)
                        .overlay { if doc.isEmptyWorkspace { EmptyWorkspaceView(doc: doc) } }
                }
                // Thumbnails are stills: no timeline.
                // The timeline stays alive in Thumbnail (hidden, no height): switching back updates it instead of
                // rebuilding it, which took ~0.1–0.2 s on long scenes.
                let showTimeline = !doc.isThumbnail && !doc.isEmptyWorkspace
                if showTimeline { ResizeHandle(height: $timelineH) }
                if !doc.isEmptyWorkspace {
                    TimelineView(doc: doc)
                        .frame(height: showTimeline ? timelineH : 0)
                        .opacity(showTimeline ? 1 : 0)
                        .allowsHitTesting(showTimeline)
                        .accessibilityHidden(!showTimeline)
                        .clipped()
                }
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

/// Shown over the viewport when the open workspace has nothing yet (a thumbnail-only project in Motion, or a
/// motion project's Thumbnail before the first page).
struct EmptyWorkspaceView: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: doc.isThumbnail ? "photo.on.rectangle.angled" : "film")
                .font(.system(size: 30, weight: .light)).foregroundStyle(UI.dim)
            Text(doc.isThumbnail ? "No thumbnails yet" : "No scenes yet")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(UI.text)
            Text(
                doc.isThumbnail
                    ? "Make a YouTube thumbnail with the same theme and assets as your motion scenes — or ask the AI to make one."
                    : "This project only has thumbnails so far. Add a scene to start on motion graphics."
            )
            .font(UI.font).foregroundStyle(UI.dim).multilineTextAlignment(.center).frame(maxWidth: 340)
            Button(doc.isThumbnail ? "Create Thumbnail" : "Create Scene") {
                if doc.isThumbnail { doc.newThumbnail() } else { doc.newScene() }
            }
            .buttonStyle(PillButtonStyle(primary: true))
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(UI.bg)
    }
}

/// Two panes stacked with a draggable divider; the split is remembered.
struct VSplit<Top: View, Bottom: View>: View {
    /// The top pane takes the whole height (no divider, no bottom pane).
    var collapsed = false
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom
    @AppStorage("thumbnail.layersSplit") private var fraction: Double = 0.42
    @State private var startFraction: Double?

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let topH = collapsed ? h : min(max(h * fraction, 120), h - 140)
            VStack(spacing: 0) {
                top().frame(width: g.size.width, height: topH).clipped()
                if !collapsed {
                Rectangle().fill(UI.border).frame(height: 1)
                    .overlay(Color.clear.frame(height: 7).contentShape(Rectangle()).cursor(.resizeUpDown)
                        .gesture(
                            DragGesture()
                                .onChanged { v in
                                    if startFraction == nil { startFraction = fraction }
                                    fraction = min(max((startFraction ?? fraction) + v.translation.height / max(h, 1), 0.15), 0.85)
                                }
                                .onEnded { _ in startFraction = nil }))
                bottom().frame(width: g.size.width).frame(maxHeight: .infinity).clipped()
                }
            }
        }
        .clipped()
    }
}
