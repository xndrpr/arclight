import AppKit
import ArclightCore
import SwiftUI
import simd

extension GizmoSession {
    func drag(to v: CGPoint, translation: CGSize, doc: EditorDocument, vp: ViewportState) {
        let dragging = press.update(translation)
        switch mode {
        case .none, .pan, .orbitPending, .orbit: break
        default: guard dragging else { return }  // still a click
        }
        let s = vp.scale
        let c = ViewZoom.canvasPoint(v, scale: s)
        let m = Self.mods
        let snapOn = !m.contains(.command) && doc.snapping
        let threshold = 6 / s
        readoutAt = CGPoint(x: v.x + 16, y: v.y + 20)
        switch mode {
        case .none: return
        case .pan:
            doc.playing = false
            let p = Self.mouse
            vp.setPan(CGSize(width: pan0.width + p.x - startMouse.x, height: pan0.height + p.y - startMouse.y))
        case .marquee:
            marquee = CGRect(
                x: min(c.x, startC.x), y: min(c.y, startC.y), width: abs(c.x - startC.x), height: abs(c.y - startC.y))
        case .move:
            var d = CGSize(width: c.x - startC.x, height: c.y - startC.y)
            let u = items.map(\.rect).reduce(items[0].rect) { $0.union($1) }.offsetBy(dx: d.width, dy: d.height)
            if snapOn {
                let r = Snap.snap(u, xs: snapX, ys: snapY, threshold: threshold)
                d.width += r.offset.width; d.height += r.offset.height
                snapLines = r.lines
            } else {
                snapLines = []
            }
            doc.offsetLayers(items.map { ($0.node, d) }, in: nodes)
            let p = items[0].node
            readout =
                "x \(fmt((p.num("x", 0) + Double(d.width)).rounded()))  y \(fmt((p.num("y", 0) + Double(d.height)).rounded()))"
            if items.count > 1 { readout = "Δ \(fmt(Double(d.width).rounded()))  \(fmt(Double(d.height).rounded()))" }
        case .scale(let h):
            if items.count == 1 { scaleSingle(h, c, doc: doc) } else { scaleMany(h, c, doc: doc) }
        case .rotate:
            guard let it = items.first else { return }
            let r = TransformMath.rotation(
                start: it.node.num("rotation", 0), pivot: it.pivot, from: startC, to: c, snap: m.contains(.shift))
            doc.setProps([(it.node.node.id, "rotation", .number(r))])
            readout = "\(fmt(r))°"
        case .anchor(let compensate):
            guard let it = items.first else { return }
            var p = CGPoint(x: it.pivot.x + c.x - startC.x, y: it.pivot.y + c.y - startC.y)
            snapLines = []
            if snapOn {
                let r = Snap.snap(CGRect(origin: p, size: .zero), xs: snapX, ys: snapY, threshold: threshold)
                p.x += r.offset.width; p.y += r.offset.height; snapLines = r.lines
            }
            if compensate {
                moveAnchor(it, to: p, doc: doc)
            } else {
                doc.offsetLayers([(it.node, CGSize(width: p.x - it.pivot.x, height: p.y - it.pivot.y))], in: nodes)
                readout = "x \(fmt(Double(p.x).rounded()))  y \(fmt(Double(p.y).rounded()))"
            }
        case .move3D:
            guard let it = items.first, let h = doc.floorPoint(c, planeY: plane) else { return }
            let x = Double(pos0.x + h.x - hit0.x).rounded(), z = Double(pos0.z + h.z - hit0.z).rounded()
            doc.setProps([(it.node.node.id, "x", .number(x)), (it.node.node.id, "z", .number(z))])
            readout = "x \(fmt(x))  z \(fmt(z))"
        case .orbitPending:
            guard hypot(v.x - startView.x, v.y - startView.y) > 3 else { return }
            (eye0, target0) = doc.cameraEyeTarget()
            mode = .orbit
            doc.beginGesture()
            fallthrough
        case .orbit:
            let t = CGPoint(x: v.x - startView.x, y: v.y - startView.y)
            let eye = Space3D.orbit(eye: eye0, target: target0, yaw: Float(t.x * 0.006), pitch: Float(t.y * 0.006))
            doc.setCamera(eye: eye, target: target0)
            readout = "orbit"
        }
    }

    private func scaleSingle(_ h: Handle, _ c: CGPoint, doc: EditorDocument) {
        guard let it = items.first else { return }
        func unscaled(_ p: CGPoint) -> CGPoint {
            let q = toUnscaled * SIMD4<Float>(Float(p.x), Float(p.y), 0, 1)
            return CGPoint(x: CGFloat(q.x), y: CGFloat(q.y))
        }
        let f = TransformMath.scaleFactors(
            handle: h, v0: unscaled(startC), v: unscaled(c), uniform: Self.mods.contains(.shift))
        let sx = it.scale.0 * Double(f.x), sy = it.scale.1 * Double(f.y)
        doc.setProps([(it.node.node.id, "scale", TransformMath.scaleValue(sx, sy, wasArray: it.scaleArray))])
        readout =
            abs(f.x - f.y) < 1e-6
            ? "×\(fmt((sx * 100).rounded() / 100))"
            : "×\(fmt((sx * 100).rounded() / 100)) × \(fmt((sy * 100).rounded() / 100))"
    }

    /// Several layers: the union box scales from its opposite handle; positions and scales follow.
    private func scaleMany(_ h: Handle, _ c: CGPoint, doc: EditorDocument) {
        let o = h.opposite.point(on: box0.corners)
        let f = TransformMath.scaleFactors(
            handle: h, v0: CGPoint(x: startC.x - o.x, y: startC.y - o.y),
            v: CGPoint(x: c.x - o.x, y: c.y - o.y), uniform: Self.mods.contains(.shift))
        var ch: [(id: String, prop: String, value: JSONValue)] = []
        for it in items {
            let np = CGPoint(x: o.x + (it.pivot.x - o.x) * f.x, y: o.y + (it.pivot.y - o.y) * f.y)
            ch += doc.positionChanges(
                it.node, by: CGSize(width: np.x - it.pivot.x, height: np.y - it.pivot.y), in: nodes)
            let id = it.node.node.id
            ch.append(
                (
                    id, "scale",
                    TransformMath.scaleValue(
                        it.scale.0 * Double(f.x), it.scale.1 * Double(f.y), wasArray: it.scaleArray)
                ))
        }
        doc.setProps(ch)
        readout =
            "×\(fmt((Double(f.x) * 100).rounded() / 100))"
            + (abs(f.x - f.y) < 1e-6 ? "" : " × \(fmt((Double(f.y) * 100).rounded() / 100))")
    }

    /// ⌥-drag of the crosshair: new anchor under the pointer, x/y compensated so the layer stays put.
    private func moveAnchor(_ it: Item, to p: CGPoint, doc: EditorDocument) {
        let n = it.node
        let l = worldInv * SIMD4<Float>(Float(p.x), Float(p.y), 0, 1)
        let a1 = CGPoint(x: CGFloat(l.x).rounded(), y: CGFloat(l.y).rounded())
        let a0 = n.anchor
        let r = TransformMath.compensate(
            x: n.num("x", 0), y: n.num("y", 0), rotation: n.num("rotation", 0),
            scale: it.scale, anchor: a0, to: a1)
        let id = n.node.id
        doc.setProps([
            (id, "anchor", [.number(Double(a1.x)), .number(Double(a1.y))]),
            (id, "x", .number((r.x * 100).rounded() / 100)), (id, "y", .number((r.y * 100).rounded() / 100)),
        ])
        readout = "anchor \(fmt(Double(a1.x)))  \(fmt(Double(a1.y)))"
    }
}
