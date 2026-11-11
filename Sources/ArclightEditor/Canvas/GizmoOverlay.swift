import ArclightCore
import SwiftUI

/// Selection and transform overlay: move / 8-handle scale / rotate / anchor for 2D layers, multi-select and
/// marquee, floor-drag for 3D layers and ⌥-drag camera orbit. Edits auto-key animated props.
struct GizmoOverlay: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var vp: ViewportState
    let scale: CGFloat

    @StateObject private var session = GizmoSession()
    @State private var hoverCursor = NSCursor.arrow
    /// True between mouse-down and mouse-up (the first onChanged begins the session, whatever it moved).
    @State private var pressed = false
    @State private var editingText: String?
    @State private var textDraft = ""
    @FocusState private var textFocused: Bool

    var body: some View {
        let nodes = doc.playing ? [] : doc.evaluate()
        let layout = GizmoLayout.make(doc, nodes: nodes, scale: scale)
        ZStack(alignment: .topLeading) {
            Color.clear.contentShape(Rectangle())
                .onContinuousHover { phase in hover(phase, nodes: nodes, layout: layout) }
                .cursor(hoverCursor)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            if !pressed {
                                pressed = true
                                session.begin(at: g.startLocation, doc: doc, vp: vp, nodes: nodes, layout: layout)
                            }
                            session.drag(to: g.location, translation: g.translation, doc: doc, vp: vp)
                        }
                        .onEnded { _ in
                            pressed = false
                            let click = session.end(doc: doc)
                            hoverCursor = .arrow
                            // Double-click edits text. AppKit's click count instead of a simultaneous TapGesture(count: 2),
                            // which failed whenever the pointer moved a little between the clicks (trackpad taps).
                            if click, (NSApp.currentEvent?.clickCount ?? 1) >= 2 { beginTextEdit(layout.single) }
                        })
            if let q = layout.box, let id = editingText, id == doc.selection { textEditor(q, id: id) }
            SelectionBoxView(layout: layout, label: label(layout))
            if let s = nodes.first(where: { $0.node.id == doc.selection }), s.is3D { marker3D(s) }
            SnapFeedback(session: session, scale: scale, canvas: doc.canvasSize)
        }
    }

    private func label(_ L: GizmoLayout) -> String {
        if let n = L.single { return n.node.id }
        return L.multi ? "\(L.outlines.count) layers" : ""
    }

    /// Crosshair at a selected 3D layer's floor position, with a hint.
    @ViewBuilder private func marker3D(_ n: EvalNode) -> some View {
        let w = n.world.columns.3
        if let p = doc.project(SIMD3(w.x, w.y, w.z)) {
            Crosshair().overlayStroke().frame(width: 18, height: 18)
                .position(x: p.x * scale, y: p.y * scale).allowsHitTesting(false)
        }
        Text("\(n.node.id) · 3D — drag to move on the floor · ⌥-drag orbits the camera")
            .font(UI.monoSmall).foregroundStyle(UI.text).padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(UI.panel.opacity(0.85))).padding(6).allowsHitTesting(false)
    }

    private func textEditor(_ q: [CGPoint], id: String) -> some View {
        let w = max(240, min(520, q[1].x - q[0].x + 40))
        return FieldBox {
            TextField("Text", text: $textDraft, axis: .vertical)
                .font(.system(size: 14)).lineLimit(1...8)
                .focused($textFocused)
                .onSubmit { commitText(id) }
                .onExitCommand { editingText = nil }
        }
        .frame(width: w)
        .shadow(color: .black.opacity(UI.isDark ? 0.6 : 0.25), radius: 12)
        .position(x: min(q[0].x, 9999) + w / 2, y: q[3].y + 22)
        .onChange(of: textFocused) { _, f in if !f { commitText(id) } }
    }

    private func hover(_ phase: HoverPhase, nodes: [EvalNode], layout L: GizmoLayout) {
        guard !session.isActive else { return }
        switch phase {
        case .active(let p):
            let c = ViewZoom.canvasPoint(p, scale: scale)
            if L.single != nil && L.onRotate(p) {
                hoverCursor = .crosshair
            } else if let h = L.handle(at: p) {
                hoverCursor = h.isCorner ? .crosshair : (h.dir.x != 0 ? .resizeLeftRight : .resizeUpDown)
            } else if L.onPivot(p) {
                hoverCursor = .pointingHand
            } else if session.hit(c, doc: doc, pickBackgrounds: false, in: nodes) != nil {
                hoverCursor = .openHand
            } else {
                hoverCursor = .arrow
            }
        case .ended: hoverCursor = .arrow
        }
    }

    /// Double-click a text layer to edit its text in place.
    private func beginTextEdit(_ n: EvalNode?) {
        guard let n, n.node.type == "text" else { return }
        textDraft = n.str("text", "")
        editingText = n.node.id
        DispatchQueue.main.async { textFocused = true }
    }

    private func commitText(_ id: String) {
        guard editingText == id else { return }
        editingText = nil
        if doc.scene.node(id)?.props["text"] != .value(.string(textDraft)) { doc.set(id, "text", .string(textDraft)) }
        DispatchQueue.main.async { endEditing() }
    }
}

/// Box, 8 handles, rotate handle, anchor crosshair and the id tag.
private struct SelectionBoxView: View {
    let layout: GizmoLayout
    let label: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(layout.outlines.enumerated()), id: \.offset) { _, q in
                Polygon(points: q).overlayStroke(opacity: 0.6)
            }
            if let q = layout.box {
                Polygon(points: q).overlayStroke()
                if let r = layout.rotate {
                    Polygon(points: [Handle.top.point(on: q), r], closed: false).overlayStroke()
                    Circle().fill(OverlayInk.halo).overlay(Circle().stroke(OverlayInk.line, lineWidth: 1.5))
                        .frame(width: 9, height: 9).position(r)
                }
                ForEach(Handle.allCases, id: \.rawValue) { h in
                    // Hollow handles in the halo colour, outlined in the accent; bottom-right filled (the "grab" corner).
                    Rectangle().fill(h == .bottomRight ? OverlayInk.line : OverlayInk.halo.opacity(1))
                        .overlay(Rectangle().stroke(OverlayInk.line, lineWidth: 1))
                        .frame(width: h.isCorner ? 8 : 7, height: h.isCorner ? 8 : 7).position(h.point(on: q))
                }
                if let a = layout.pivot {
                    Crosshair().overlayStroke().frame(width: 14, height: 14).position(a)
                    Circle().overlayStroke().frame(width: 6, height: 6).position(a)
                }
                if !label.isEmpty {
                    Text(label).font(UI.monoSmall).foregroundStyle(OverlayInk.chipText).padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 2).fill(OverlayInk.chip))
                        .fixedSize().position(x: q[0].x + 30, y: q[0].y - 9)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Dashed snap lines, marquee rectangle and the live value chip.
private struct SnapFeedback: View {
    @ObservedObject var session: GizmoSession
    let scale: CGFloat
    let canvas: CGSize

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(session.snapLines, id: \.self) { l in
                Path { p in
                    if l.axis == .x {
                        p.move(to: CGPoint(x: l.value * scale, y: 0));
                        p.addLine(to: CGPoint(x: l.value * scale, y: canvas.height * scale))
                    } else {
                        p.move(to: CGPoint(x: 0, y: l.value * scale));
                        p.addLine(to: CGPoint(x: canvas.width * scale, y: l.value * scale))
                    }
                }
                // snap lines: a colour no video uses for chrome
                .stroke(UI.danger, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let r = session.marquee {
                let v = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
                Rectangle().fill(OverlayInk.line.opacity(0.08))
                    .overlay(Rectangle().overlayStroke(dash: [3, 3]))
                    .frame(width: v.width, height: v.height).position(x: v.midX, y: v.midY)
            }
            if let t = session.readout {
                Text(t).font(UI.monoSmall).foregroundStyle(OverlayInk.chipText).padding(.horizontal, 6).padding(
                    .vertical, 2
                )
                .background(Capsule().fill(OverlayInk.chip)).fixedSize()
                .position(session.readoutAt)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Open or closed polyline through view points.
private struct Polygon: Shape {
    let points: [CGPoint]
    var closed = true
    func path(in _: CGRect) -> Path {
        var p = Path()
        p.addLines(points)
        if closed { p.closeSubpath() }
        return p
    }
}

private struct Crosshair: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.move(to: CGPoint(x: r.minX, y: r.midY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
        return p
    }
}
