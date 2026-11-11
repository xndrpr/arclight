import AppKit
import ArclightCore
import SwiftUI

extension Ruler {
    // MARK: Drawing

    func drawRuler(_ ctx: GraphicsContext, _ size: CGSize, _ map: TimeMap) {
        // Past the scene end: hatched (not rendered); the ruler keeps counting.
        TimelineInk.drawPastEnd(ctx, size, endX: map.x(doc.scene.duration))
        ctx.fill(Path(CGRect(x: 0, y: TL.markerBandH, width: size.width, height: 1)), with: .color(UI.border))
        // Pick a label step that leaves ≥ 70 px between labels; frames when zoomed in far.
        let steps = [1 / doc.fps, 2 / doc.fps, 5 / doc.fps, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600]
        let major = steps.first { CGFloat($0) * map.pps >= 70 } ?? 600
        // Minor ticks only when they stay ≥ 6 px apart (never a solid bar).
        let minor = CGFloat(major / 5) * map.pps >= 6 ? major / 5 : major
        var t = (doc.tlOffset / minor).rounded(.down) * minor
        let end = doc.tlOffset + doc.tlVisible
        var guardCount = 0
        while t <= end + 1e-6 && guardCount < 2000 {
            guardCount += 1
            let x = map.x(t)
            let isMajor = abs((t / major).rounded() * major - t) < 1e-6
            if isMajor {
                ctx.fill(Path(TimelineInk.lineRect(x, y: size.height - 9, width: 1, height: 9)), with: .color(UI.faint))
                // Leave room for the END tab (labels under it would collide).
                let ex = map.x(doc.scene.duration)
                if x + 3 < ex + 32 && x + 30 > ex - 2 { t += minor; continue }
                let label =
                    major < 1 && major < 0.25
                    ? "f\(Int((t * doc.fps).rounded()))" : String(format: "%gs", (t * 100).rounded() / 100)
                ctx.draw(
                    Text(label).font(UI.monoSmall).foregroundColor(UI.label2),
                    at: CGPoint(x: x + 3, y: TL.markerBandH + 8), anchor: .leading)
            } else {
                ctx.fill(
                    Path(TimelineInk.lineRect(x, y: size.height - 4, width: 1, height: 4)), with: .color(UI.border))
            }
            t += minor
        }
    }

    func drawWorkArea(_ ctx: GraphicsContext, _ size: CGSize, _ map: TimeMap, _ w: ClosedRange<Double>) {
        let a = map.x(w.lowerBound), b = map.x(w.upperBound)
        let band = CGRect(x: a, y: TL.markerBandH + 1, width: max(b - a, 1), height: size.height - TL.markerBandH - 1)
        ctx.fill(Path(band), with: .color(UI.text.opacity(doc.loopEnabled ? 0.08 : 0.04)))
        let bar = CGRect(x: a, y: size.height - 3, width: max(b - a, 1), height: 3)
        ctx.fill(Path(bar), with: .color(UI.text.opacity(doc.loopEnabled ? 0.7 : 0.35)))
        for x in [a, b] {
            ctx.fill(
                Path(TimelineInk.lineRect(x, y: TL.markerBandH + 1, width: 1, height: size.height)),
                with: .color(UI.text.opacity(0.5)))
        }
    }

    func drawEnd(_ ctx: GraphicsContext, _ size: CGSize, _ map: TimeMap, _ d: Double) {
        // Scene end marker — drag it to change the duration.
        let ex = map.x(d)
        let active = drag == .end || hoverEnd
        let endColor = active ? UI.accent : TimelineInk.endLine
        ctx.fill(Path(TimelineInk.lineRect(ex, width: 2, height: size.height)), with: .color(endColor))
        var tab = Path()
        let label = active ? "END \(fmt((d * 100).rounded() / 100))s" : "END"
        let w =
            active
            ? ctx.resolve(Text(label).font(Self.endFont)).measure(in: CGSize(width: 200, height: 20)).width + 10 : 30
        tab.addRoundedRect(
            in: CGRect(x: ex - 1, y: TL.markerBandH + 2, width: w, height: 13), cornerSize: CGSize(width: 3, height: 3))
        ctx.fill(tab, with: .color(endColor))
        ctx.draw(
            Text(label).font(Self.endFont).foregroundColor(UI.onAccent.opacity(active ? 1 : 0.95)),
            at: CGPoint(x: ex - 1 + w / 2, y: TL.markerBandH + 8.5))
    }

    /// Flags with names in the top band, truncated to the room before the next marker.
    func drawMarkers(_ ctx: GraphicsContext, _ size: CGSize, _ map: TimeMap) {
        let ms = doc.scene.markers ?? []
        for (i, m) in ms.enumerated() {
            let x = map.x(m.t)
            let next = i + 1 < ms.count ? map.x(ms[i + 1].t) : size.width + 200
            guard next > -10, x < size.width + 10 else { continue }
            let c = MarkerStyle.color(m)
            let active = hoverMarker == m.name || drag == .marker(m.name, m.t) || renaming == m.name
            ctx.fill(
                Path(TimelineInk.lineRect(x, width: 1, height: size.height)), with: .color(c.opacity(active ? 1 : 0.8)))
            let room = next - x - 3
            let label = MarkerStyle.fit(m.name, room: room - 8) {
                ctx.resolve(Text($0).font(MarkerStyle.font)).measure(in: CGSize(width: 1000, height: 20)).width
            }
            let w =
                label.map {
                    ctx.resolve(Text($0).font(MarkerStyle.font)).measure(in: CGSize(width: 1000, height: 20)).width + 8
                } ?? 7
            var flag = Path()
            flag.addRoundedRect(
                in: CGRect(x: x, y: 1, width: w, height: TL.markerBandH - 2), cornerSize: CGSize(width: 2, height: 2))
            ctx.fill(flag, with: .color(c.opacity(active ? 1 : 0.85)))
            if let label {
                ctx.draw(
                    Text(label).font(MarkerStyle.font).foregroundColor(MarkerStyle.textColor(m)),
                    at: CGPoint(x: x + 4, y: TL.markerBandH / 2), anchor: .leading)
            }
        }
    }
}
