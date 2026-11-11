import AppKit
import ArclightCore
import SwiftUI

/// The AI panel as a card floating over the viewport column: takes no layout space, drags by its header
/// (snapping into corners), resizes from its bottom corners, collapses to its header, and remembers all of it
/// (`AIPanelLayout`). In a very small window it covers the viewport like a sheet.
///
/// An in-window overlay rather than a separate `NSPanel`: it follows the window everywhere (full screen,
/// Spaces, minimise, tabs) with no window management, keeps the editor window key so transport keys and
/// menus keep working while you watch the AI, themes with the window, and shows in off-screen snapshots.
/// Apply it as an overlay of the column it floats over.
struct FloatingAIPanel: View {
    @ObservedObject var doc: EditorDocument
    /// The top-bar AI pill's frame (global), so the panel opens out of it and closes back into it.
    var pill: CGRect = .zero
    @AppStorage(Pref.aiPanel) private var open = false
    @AppStorage(Pref.aiFloat) private var raw = ""
    /// Header drag in progress (translation).
    @State private var drag: CGSize?
    /// Corner resize in progress: frame at the start, and the live layout.
    @State private var resizeStart: CGRect?
    @State private var live: AIPanelLayout?
    @State private var window: NSWindow?
    /// Panel frame in window space while open (registered with `FloatingRegions` once the window is known).
    @State private var region: CGRect?

    private var saved: AIPanelLayout { raw.isEmpty ? AIPanelLayout() : AIPanelLayout.decode(raw) ?? AIPanelLayout() }

    var body: some View {
        GeometryReader { g in
            let c = g.size
            let layout = live ?? saved
            let sheet = layout.isSheet(in: c)
            let f = frame(layout, in: c, sheet: sheet)
            let origin = g.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                if open {
                    card(layout, frame: f, container: c, sheet: sheet)
                        .frame(width: f.width, height: f.height)
                        .offset(x: f.minX, y: f.minY)
                        .transition(transition(f.offsetBy(dx: origin.x, dy: origin.y)))
                }
            }
            .frame(width: c.width, height: c.height, alignment: .topLeading)
            .onChange(of: open ? f.offsetBy(dx: origin.x, dy: origin.y) : .null, initial: true) { _, r in
                region = r.isNull ? nil : r
                if let window { FloatingRegions.set(region, for: window) }
            }
        }
        .background(
            WindowObserver { w in
                if let old = window, old !== w { FloatingRegions.set(nil, for: old) }
                window = w
                if let w { FloatingRegions.set(region, for: w) }
            }
        )
        .animation(Motion.snappy, value: open)
        .onAppear {
            FloatingRegions.installFocusTracking(); _ = AIPanelLayout.load()
        }
        .onDisappear { if let window { FloatingRegions.set(nil, for: window) } }
    }

    private func frame(_ l: AIPanelLayout, in c: CGSize, sheet: Bool) -> CGRect {
        let f = l.frame(in: c)
        guard let d = drag, !sheet else { return f }
        return AIPanelLayout.clamped(f.offsetBy(dx: d.width, dy: d.height), in: c)
    }

    /// Scale + fade out of the pill (fade only with reduced motion).
    private func transition(_ global: CGRect) -> AnyTransition {
        guard !Motion.reduce else { return .opacity }
        var anchor = UnitPoint.topTrailing
        if pill.width > 0, global.width > 0, global.height > 0 {
            anchor = UnitPoint(
                x: min(1, max(0, (pill.midX - global.minX) / global.width)),
                y: min(1, max(0, (pill.midY - global.minY) / global.height)))
        }
        return .scale(scale: 0.9, anchor: anchor).combined(with: .opacity)
    }

    private func card(_ l: AIPanelLayout, frame f: CGRect, container c: CGSize, sheet: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(spacing: 0) {
            AIPanelHeader(
                doc: doc, collapsed: l.collapsed, draggable: !sheet,
                toggleCollapsed: {
                    var n = saved; n.collapsed.toggle(); withMotion(Motion.snappy) { raw = n.encoded }
                },
                close: { open = false }
            )
            .gesture(headerDrag(l, frame: f, container: c), including: sheet ? .subviews : .all)
            if !l.collapsed {
                Hairline()
                AIPanelContent(doc: doc)
                    .transition(.opacity)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(UI.panel)
        .clipShape(shape)
        .overlay(shape.strokeBorder(UI.border, lineWidth: 1))
        .overlay(alignment: .bottomTrailing) {
            if !sheet && !l.collapsed { resizeHandle(l, frame: f, container: c, leading: false) }
        }
        .overlay(alignment: .bottomLeading) {
            if !sheet && !l.collapsed { resizeHandle(l, frame: f, container: c, leading: true) }
        }
        .compositingGroup()
        .shadow(color: Color.black.opacity(UI.isDark ? 0.55 : 0.16), radius: 18, y: 8)
        .shadow(color: Color.black.opacity(UI.isDark ? 0.3 : 0.06), radius: 2, y: 1)
        .contentShape(shape)
    }

    private func headerDrag(_ l: AIPanelLayout, frame f: CGRect, container c: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { v in drag = v.translation }
            .onEnded { _ in
                let settled = l.settled(f, in: c)
                withMotion(Motion.snappy) {
                    drag = nil; raw = settled.encoded
                }
            }
    }

    private func resizeHandle(_ l: AIPanelLayout, frame f: CGRect, container c: CGSize, leading: Bool) -> some View {
        ResizeGrip(leading: leading)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        let start = resizeStart ?? f
                        if resizeStart == nil { resizeStart = f }
                        live = saved.resized(from: start, by: v.translation, leadingHandle: leading, in: c)
                    }
                    .onEnded { _ in
                        if let live { raw = live.encoded }
                        live = nil; resizeStart = nil
                    })
    }
}

/// Bottom-corner resize grip: two short diagonal strokes.
private struct ResizeGrip: View {
    let leading: Bool
    @State private var hover = false

    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            for k in [5.0, 9.0] {
                if leading {
                    p.move(to: CGPoint(x: 3, y: size.height - 3 - k));
                    p.addLine(to: CGPoint(x: 3 + k, y: size.height - 3))
                } else {
                    p.move(to: CGPoint(x: size.width - 3, y: size.height - 3 - k));
                    p.addLine(to: CGPoint(x: size.width - 3 - k, y: size.height - 3))
                }
            }
            ctx.stroke(
                p, with: .color(hover ? UI.label2 : UI.faint), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        }
        .frame(width: 18, height: 18)
        .hitArea()
        .onHover { hover = $0 }
        .resizeCursor(leading ? .bottomLeading : .bottomTrailing)
        .help("Drag to resize")
    }
}

private extension View {
    @ViewBuilder func resizeCursor(_ corner: UnitPoint) -> some View {
        if #available(macOS 15.0, *) {
            pointerStyle(.frameResize(position: corner == .bottomLeading ? .bottomLeading : .bottomTrailing))
        } else {
            cursor(.crosshair)
        }
    }
}

/// Header: what the AI is doing, and the panel's own controls. Doubles as the drag handle.
struct AIPanelHeader: View {
    @ObservedObject var doc: EditorDocument
    let collapsed: Bool
    var draggable = true
    let toggleCollapsed: () -> Void
    let close: () -> Void
    @ObservedObject private var monitor = AgentMonitor.shared

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = AIStatus.compute(for: doc, agents: monitor.agents, now: ctx.date)
            let busy = s.isBusy
            HStack(spacing: 7) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(UI.ai)
                Text("AI").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(UI.text)
                StatusDot(color: s.dotColor, pulsing: busy)
                Text(s.text).font(UI.small).foregroundStyle(s.kind == .none ? UI.dim : UI.label2).lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
                    .animation(UI.fade, value: s.text)
                Spacer(minLength: 4)
                IconButton(
                    symbol: "folder", help: "Copy project path — paste it to your AI agent so it opens this project"
                ) {
                    MCPSetup.copy(doc.url.path)
                    doc.flash("Project path copied — paste it to your AI agent")
                }
                IconButton(
                    symbol: collapsed ? "chevron.down" : "chevron.up",
                    help: collapsed ? "Expand the AI panel" : "Collapse to this bar",
                    action: toggleCollapsed)
                IconButton(symbol: "xmark", help: "Close the AI panel (⌥⌘A)", action: close)
            }
            .padding(.leading, 12).padding(.trailing, 6)
            .frame(height: AIPanelLayout.headerHeight)
            .background(UI.panel)
            .hitArea()
            .cursor(draggable ? .openHand : .arrow)
            .help(draggable ? "Drag to move · snaps to the corners" : "")
        }
    }
}

/// Lets the top-bar pill report where it is (global frame), for the panel's open/close animation.
struct AIPillFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}
