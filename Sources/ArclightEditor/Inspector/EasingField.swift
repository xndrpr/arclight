import ArclightCore
import SwiftUI

/// A small drawing of an easing curve (x = time, y = progress).
private struct EasingCurve: View {
    let easing: Easing
    var color: Color = UI.text
    var lineWidth: CGFloat = 1.4

    var body: some View {
        Canvas { ctx, size in
            let pad: CGFloat = 3
            let w = size.width - pad * 2, h = size.height - pad * 2
            // Leave room for overshoot (outBack, spring).
            let lo = -0.25, hi = 1.25
            func pt(_ x: Double, _ y: Double) -> CGPoint {
                CGPoint(x: pad + CGFloat(x) * w, y: pad + CGFloat((hi - y) / (hi - lo)) * h)
            }
            var base = Path(); base.move(to: pt(0, 0)); base.addLine(to: pt(1, 0))
            ctx.stroke(base, with: .color(UI.border), lineWidth: 1)
            var p = Path()
            let n = 48
            for k in 0...n {
                let x = Double(k) / Double(n)
                let q = pt(x, easing.apply(x))
                if k == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            ctx.stroke(
                p, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }
}

extension Easing {
    var label: String {
        switch self {
        case .bezier(let a, let b, let c, let d):
            return "bezier(" + [a, b, c, d].map(fmt).joined(separator: ", ") + ")"
        default: return json.string ?? "linear"
        }
    }
}

/// Easing picker: shows the curve and name; the popover has every named curve as a thumbnail and a
/// custom cubic-bezier editor with two draggable handles.
struct EasingField: View {
    let value: JSONValue?
    let commit: (JSONValue) -> Void
    @State private var open = false

    private var easing: Easing { value.flatMap { try? Easing(json: $0) } ?? .linear }

    var body: some View {
        FieldButton(spacing: 6, height: 26, action: { open = true }) {
            EasingCurve(easing: easing).frame(width: 22, height: 18)
            Text(easing.label).font(UI.mono).foregroundStyle(UI.text).lineLimit(1).truncationMode(.tail)
        }
        .popover(isPresented: $open, arrowEdge: .leading) {
            EasingPicker(current: easing) { commit($0.json) }
        }
    }
}

private struct EasingPicker: View {
    let current: Easing
    let commit: (Easing) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Easing").font(.system(size: 12, weight: .semibold)).foregroundStyle(UI.text)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(62), spacing: 6), count: 5), spacing: 6) {
                ForEach(Easing.names, id: \.self) { n in cell(Easing(n), n) }
            }
            Hairline()
            SmallCapsLabel("Custom curve")
            BezierEditor(initial: bezierPoints(current)) { commit(.bezier($0[0], $0[1], $0[2], $0[3])) }
        }
        .popoverChrome()
    }

    private func cell(_ e: Easing, _ name: String) -> some View {
        let on = e == current
        return Button {
            commit(e)
        } label: {
            VStack(spacing: 2) {
                EasingCurve(easing: e, lineWidth: 1.2).frame(width: 44, height: 30)
                Text(name).font(.system(size: 9)).foregroundStyle(on ? UI.text : UI.dim).lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 62, height: 50)
            .background(RoundedRectangle(cornerRadius: 6).fill(on ? UI.selected : UI.field))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? UI.accent : UI.fieldBorder, lineWidth: on ? 1.5 : 1))
            .hitArea()
        }
        .buttonStyle(.plain).cursor(.pointingHand).help(name)
    }

    /// Bezier handles for the editor: the current bezier, or a close match for common curves.
    private func bezierPoints(_ e: Easing) -> [Double] {
        if case .bezier(let a, let b, let c, let d) = e { return [a, b, c, d] }
        switch e.json.string ?? "" {
        case "linear": return [0, 0, 1, 1]
        case "inOutCubic", "inOutSine", "inOutQuad": return [0.65, 0, 0.35, 1]
        case let n where n.hasPrefix("out"): return [0.16, 1, 0.3, 1]
        case let n where n.hasPrefix("in"): return [0.7, 0, 0.84, 0]
        default: return [0.25, 0.1, 0.25, 1]
        }
    }
}

/// Cubic-bezier editor: drag the two handles; writes `[x1, y1, x2, y2]` on release.
private struct BezierEditor: View {
    let initial: [Double]
    let commit: ([Double]) -> Void
    @State private var pts: [Double] = []
    @State private var dragStart: [Double]?

    private let side: CGFloat = 170
    private let lo = -0.5, hi = 1.5

    var body: some View {
        let p = pts.count == 4 ? pts : initial
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in draw(ctx, p) }
                handle(0, p)
                handle(1, p)
            }
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: 6).fill(UI.field))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.fieldBorder))
            VStack(alignment: .leading, spacing: 6) {
                Text(p.map { String(format: "%.2f", $0) }.joined(separator: ", ")).font(UI.monoSmall).foregroundStyle(
                    UI.label2)
                Button("Apply") { commit(p) }.buttonStyle(PillButtonStyle(primary: true))
                Text("Drag the handles. Y can overshoot for a bounce.").font(UI.small).foregroundStyle(UI.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 140, alignment: .leading)
        }
        .onAppear { pts = initial }
    }

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        CGPoint(x: CGFloat(x) * (side - 24) + 12, y: CGFloat((hi - y) / (hi - lo)) * side)
    }

    private func draw(_ ctx: GraphicsContext, _ p: [Double]) {
        let a = point(0, 0), b = point(1, 1)
        let c1 = point(p[0], p[1]), c2 = point(p[2], p[3])
        var frame = Path(); frame.move(to: point(0, 0)); frame.addLine(to: point(1, 0))
        frame.move(to: point(0, 1)); frame.addLine(to: point(1, 1))
        ctx.stroke(frame, with: .color(UI.border), lineWidth: 1)
        var arms = Path(); arms.move(to: a); arms.addLine(to: c1); arms.move(to: b); arms.addLine(to: c2)
        ctx.stroke(arms, with: .color(UI.faint), lineWidth: 1)
        var curve = Path(); curve.move(to: a); curve.addCurve(to: b, control1: c1, control2: c2)
        ctx.stroke(curve, with: .color(UI.text), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
    }

    private func handle(_ k: Int, _ p: [Double]) -> some View {
        let c = point(p[k * 2], p[k * 2 + 1])
        return Circle().fill(UI.text).frame(width: 11, height: 11)
            .overlay(Circle().stroke(UI.panel, lineWidth: 1.5))
            .offset(x: c.x - 5.5, y: c.y - 5.5)
            .gesture(
                DragGesture(coordinateSpace: .local).onChanged { g in
                    var q = pts.count == 4 ? pts : initial
                    if dragStart == nil { dragStart = q }
                    let s0 = point(dragStart![k * 2], dragStart![k * 2 + 1])
                    let x = min(max(Double((s0.x + g.translation.width - 12) / (side - 24)), 0), 1)
                    let y = min(max(hi - Double((s0.y + g.translation.height) / side) * (hi - lo), lo), hi)
                    q[k * 2] = (x * 100).rounded() / 100; q[k * 2 + 1] = (y * 100).rounded() / 100
                    pts = q
                }.onEnded { _ in
                    dragStart = nil; commit(pts)
                }
            )
            .cursor(.openHand)
    }
}
