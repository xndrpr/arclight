import AppKit
import ArclightCore
import SwiftUI

/// Projects · project / scene names ………… AI status · problems · theme · canvas · performance · help · settings · Export.
/// Narrow windows shed labels (AI status, Performance, fps) before anything can overlap; names truncate.
struct TopBar: View {
    @ObservedObject var doc: EditorDocument
    let export: () -> Void
    @State private var renamingProject = false
    @State private var width: CGFloat = 1600
    /// Room for the traffic lights (12 in full screen, where they're hidden).
    @State private var leading: CGFloat = TopBar.defaultLeading
    /// Matches the window's title-bar row (the bar sits in it, beside the traffic lights).
    @State private var height: CGFloat = TopBar.defaultHeight
    private static let defaultHeight: CGFloat = 42
    private static let defaultLeading: CGFloat = 76
    private static let compactLeading: CGFloat = 12

    private enum Density: Int, Comparable {
        case compact, medium, full
        static func < (a: Density, b: Density) -> Bool { a.rawValue < b.rawValue }
    }

    private var density: Density { width >= 1400 ? .full : width >= 1220 ? .medium : .compact }

    var body: some View {
        HStack(spacing: 8) {
            HomeLogoButton()
            Text("/").foregroundStyle(UI.faint)
            InlineRename(
                text: doc.project.name, placeholder: "Project name", bold: true, editing: $renamingProject,
                help: "Project — click to rename"
            ) { n in
                doc.renameProject(n)
                // This project's own window, which need not be the key one by the time the rename commits.
                let own = NSApp.windows.first { ($0.windowController as? EditorWindowController)?.doc === doc }
                own?.title = doc.project.name
            }
            .layoutPriority(1)
            Text("/").foregroundStyle(UI.faint)
            SceneNameRename(doc: doc)
            Spacer(minLength: 12)
            right.fixedSize().layoutPriority(2)
        }
        .padding(.leading, leading).padding(.trailing, 12).frame(height: height)
        .environment(\.barHitHeight, height)
        // Empty bar space moves the window (the content itself never does: `AppHostingView`); in front of the fill.
        .background(WindowDragArea())
        .background(UI.bg)
        .background(
            GeometryReader { g in
                Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { _, w in width = w }
            }
        )
        .background(
            WindowObserver { w in
                leading = TopBar.leading(for: w); height = TopBar.height(for: w)
            }
        )
        .animation(UI.fade, value: density)
        .onReceive(NotificationCenter.default.publisher(for: .renameProject)) { n in
            if (n.object as? EditorDocument) === doc { renamingProject = true }
        }
    }

    private var right: some View {
        HStack(spacing: 8) {
            AIStatusPill(doc: doc, compact: density == .compact)
            ProblemsButton(doc: doc)
            if let b = doc.busy {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                    if density == .full { Text(b).font(UI.small).foregroundStyle(UI.dim).lineLimit(1) }
                }
                .help(b)
            }
            ThemeQuickButton(doc: doc)
            CanvasMenu(doc: doc, showFPS: density > .compact)
            PerformanceToggle(doc: doc, label: density == .full)
            IconButton(symbol: "keyboard", help: "Keyboard shortcuts (⌘?)") {
                NotificationCenter.default.post(name: .showShortcuts, object: doc)
            }
            IconButton(symbol: "gearshape", help: "Settings (⌘,)") {
                (NSApp.delegate as? AppDelegate)?.showSettings(nil)
            }
            Button("Export", action: export).buttonStyle(PillButtonStyle(primary: true)).help("Export video (⌘E)")
        }
    }

    /// Leading inset that puts the first button right after the traffic lights (or 12 pt when they're hidden).
    static func leading(for w: NSWindow?) -> CGFloat {
        guard let w else { return defaultLeading }
        // Full screen (also mid-transition, and windows sized to fill the screen by full-screen tiling): the traffic
        // lights live in a separate, auto-hiding title-bar window, so nothing sits next to our bar.
        if w.styleMask.contains(.fullScreen) { return compactLeading }
        // Borderless (the off-screen snapshot window): assume the standard buttons.
        if !w.styleMask.contains(.titled) { return defaultLeading }
        // The buttons must actually be visible in *this* window; otherwise there's nothing to make room for.
        guard let zoom = w.standardWindowButton(.zoomButton), !zoom.isHidden, zoom.alphaValue > 0.01,
            zoom.window === w, zoom.superview?.isHidden == false
        else { return compactLeading }
        return ceil(zoom.convert(zoom.bounds, to: nil).maxX) + 10
    }

    /// Height of the window's title-bar row, so the bar's contents line up with the traffic lights.
    /// Full screen / borderless (no title bar in the content): the default.
    static func height(for w: NSWindow?) -> CGFloat {
        guard let w, w.styleMask.contains(.titled), !w.styleMask.contains(.fullScreen) else { return defaultHeight }
        let titlebar = w.frame.height - w.contentLayoutRect.height
        return titlebar >= 28 ? max(38, titlebar.rounded()) : defaultHeight
    }
}

/// "⚡ Performance" — half-resolution preview while on.
private struct PerformanceToggle: View {
    @ObservedObject var doc: EditorDocument
    var label = true
    @State private var hover = false

    var body: some View {
        let on = doc.performance
        Button {
            doc.performance.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "bolt.fill").font(.system(size: 10))
                if label { Text("Performance").font(UI.small).lineLimit(1) }
            }
            .foregroundStyle(on ? UI.onAccent : (hover ? UI.text : UI.label2))
            .padding(.horizontal, label ? 9 : 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? UI.accent : hover ? UI.hover : UI.raised))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? .clear : UI.border))
            .barHit()
        }
        .buttonStyle(.plain).onHover { hover = $0 }.cursor(.pointingHand)
        .help(
            "Performance mode is \(on ? "on" : "off"): preview at half resolution if playback lags. Export is always full quality. (⇧⌘P)"
        )
    }
}

private struct SceneNameRename: View {
    @ObservedObject var doc: EditorDocument
    @State private var editing = false
    var body: some View {
        InlineRename(
            text: doc.scene.name ?? doc.scene.id, placeholder: "Scene name", bold: false, editing: $editing,
            help: "Current scene — click to rename"
        ) { n in doc.renameScene(doc.scene.id, n) }
    }
}

/// "1920×1080 · 30 fps" — click for canvas presets (vertical, square, 4K…), frame rate and Settings.
private struct CanvasMenu: View {
    @ObservedObject var doc: EditorDocument
    var showFPS = true
    @State private var hover = false

    var body: some View {
        let w = Int(doc.canvasSize.width), h = Int(doc.canvasSize.height)
        Menu {
            Section("Canvas — whole project") {
                ForEach(EditorDocument.presets, id: \.self) { p in
                    let on = p.w == doc.project.size.first && p.h == doc.project.size.last
                    Button("\(p.title) · \(p.subtitle)  —  \(p.w)×\(p.h)" + (on ? "  ✓" : "")) {
                        doc.setProjectCanvas(width: p.w, height: p.h)
                    }
                }
            }
            Section("Frame rate") {
                ForEach(EditorDocument.frameRates, id: \.self) { f in
                    Button("\(fmt(f)) fps" + (abs(doc.project.fps - f) < 0.001 ? "  ✓" : "")) { doc.setProjectFPS(f) }
                }
            }
            Divider()
            Button("Custom size, per-scene overrides…") { (NSApp.delegate as? AppDelegate)?.showSettings(nil) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: w >= h ? "rectangle" : "rectangle.portrait").font(.system(size: 10))
                Text("\(w)×\(h)" + (showFPS ? " · \(fmt(doc.fps)) fps" : "")).font(UI.monoSmall).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .foregroundStyle(hover ? UI.text : UI.label2)
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(hover ? UI.hover : UI.raised))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.border))
            .barHit()
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().cursor(.pointingHand)
        .onHover { hover = $0 }
        .help("Canvas size and frame rate: \(w)×\(h) at \(fmt(doc.fps)) fps")
    }
}

/// The logo, first in the bar right after the window buttons. Click it to go to all projects (⇧⌘H);
/// on hover it shows a grid hint so the action is discoverable.
private struct HomeLogoButton: View {
    @State private var hover = false
    var body: some View {
        Button {
            EditorWindowController.frontmost?.goHome(nil)
        } label: {
            // Fixed size on hover (only the background changes), so nothing shifts under a moving pointer.
            LogoMark(height: 13)
                .padding(.horizontal, 6).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 6).fill(hover ? UI.hover : .clear))
                .barHit()
        }
        .buttonStyle(.plain).cursor(.pointingHand)
        .onHover { h in withAnimation(UI.fade) { hover = h } }
        .help("All projects (⇧⌘H)")
        .padding(.leading, -6)  // the logo itself lines up with the bar's left inset, not its hover background
    }
}
