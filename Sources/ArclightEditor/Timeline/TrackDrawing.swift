import AppKit
import ArclightCore
import SwiftUI

/// Draws the track area: rows, bars, diamonds (selected ones highlighted), the past-END hatch on top,
/// work area, marker lines and the playhead.
struct TrackDrawing {
    let doc: EditorDocument
    let rows: [TLRow]
    let map: TimeMap
    let selected: Set<KeyRef>

    func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let d = doc.scene.duration
        let ex = map.x(d)
        if let w = doc.workArea {
            ctx.fill(
                Path(
                    CGRect(
                        x: map.x(w.lowerBound), y: 0, width: max(1, map.x(w.upperBound) - map.x(w.lowerBound)),
                        height: size.height)),
                with: .color(UI.text.opacity(0.03)))
        }
        // Selected key times per row: node → local times (all props) and node.prop → local times.
        var selByNode: [String: Set<Double>] = [:], selByProp: [String: Set<Double>] = [:]
        for k in selected {
            selByNode[k.node, default: []].insert(k.t); selByProp["\(k.node).\(k.prop)", default: []].insert(k.t)
        }
        for (i, r) in rows.enumerated() { drawRow(ctx, size, i, r, d, selByNode, selByProp) }
        // Over the rows, so bars and keys that run past END read as "outside the scene".
        TimelineInk.drawPastEnd(ctx, size, endX: ex)
        TimelineInk.drawEndLine(ctx, size, endX: ex)
        if size.width - ex > 330 {
            ctx.draw(
                Text("Past the end · not rendered — drag END on the ruler to extend").font(.system(size: 10.5))
                    .foregroundColor(UI.dim),
                at: CGPoint(x: max(ex, 0) + 12, y: CGFloat(rows.count) * TL.rowH + 16), anchor: .leading)
        }
        for m in doc.scene.markers ?? [] {
            let x = map.x(m.t)
            guard x > -2, x < size.width + 2 else { continue }
            ctx.fill(
                Path(TimelineInk.lineRect(x, width: 1, height: size.height)),
                with: .color(MarkerStyle.color(m).opacity(0.35)))
        }
        TimelineInk.drawPlayhead(ctx, size, x: map.x(doc.time))
    }

    private func drawRow(
        _ ctx: GraphicsContext, _ size: CGSize, _ i: Int, _ r: TLRow, _ d: Double,
        _ selByNode: [String: Set<Double>], _ selByProp: [String: Set<Double>]
    ) {
        let y = CGFloat(i) * TL.rowH
        let selected = doc.selectedIds.contains(r.node.id)
        if selected && r.prop == nil {
            ctx.fill(
                Path(CGRect(x: 0, y: y, width: size.width, height: TL.rowH)), with: .color(UI.selected.opacity(0.5)))
        }
        ctx.fill(
            Path(CGRect(x: 0, y: y + TL.rowH - 1, width: size.width, height: 1)), with: .color(TimelineInk.rowLine))
        if r.prop == nil && !LayerTree.isPinned(r.node.id) {  // camera/look rows have keys only, no bar
            let a = map.x(r.node.start ?? 0), b = map.x(r.node.end ?? d)
            let bar = CGRect(x: a, y: y + 5, width: max(b - a, 2), height: TL.rowH - 10)
            let hidden = r.node.props["visible"] == .value(false)
            let shape = Path(roundedRect: bar, cornerRadius: 3)
            ctx.fill(
                shape,
                with: .color(hidden ? TimelineInk.barHidden : (selected ? TimelineInk.barSelected : TimelineInk.bar)))
            if let tint = LayerLabel.color(r.node), !hidden {
                ctx.fill(shape, with: .color(tint.opacity(selected ? 0.5 : 0.38)))
            }
            ctx.stroke(shape, with: .color(selected ? UI.accent.opacity(0.8) : TimelineInk.barStroke), lineWidth: 1)
            if selected {  // trim handles: small grips at both edges
                for x in [a + 2, b - 4] {
                    ctx.fill(
                        Path(roundedRect: CGRect(x: x, y: y + TL.rowH / 2 - 5, width: 2, height: 10), cornerRadius: 1),
                        with: .color(UI.accent.opacity(0.6)))
                }
            }
        }
        let start = r.node.start ?? 0
        let sel = (r.prop.map { selByProp["\(r.node.id).\($0)"] } ?? selByNode[r.node.id]) ?? []
        for t in TL.keyTimes(r) {
            let x = map.x(t), cy = y + TL.rowH / 2, s: CGFloat = r.prop == nil ? 4.5 : 5
            guard x > -10, x < size.width + 10 else { continue }
            let isSel = sel.contains { abs(start + $0 - t) < 1e-3 }
            let sz = isSel ? s + 1 : s
            var p = Path()
            p.move(to: CGPoint(x: x, y: cy - sz)); p.addLine(to: CGPoint(x: x + sz, y: cy))
            p.addLine(to: CGPoint(x: x, y: cy + sz)); p.addLine(to: CGPoint(x: x - sz, y: cy)); p.closeSubpath()
            let atHead = abs(t - doc.time) < 0.5 / doc.fps
            let fill: Color =
                isSel
                ? TimelineInk.selectedKey
                : (atHead ? UI.accent : (r.prop == nil ? TimelineInk.key : TimelineInk.propKey))
            ctx.fill(p, with: .color(fill))
            ctx.stroke(p, with: .color(isSel ? UI.text : TimelineInk.keyOutline), lineWidth: 1)
        }
    }
}
