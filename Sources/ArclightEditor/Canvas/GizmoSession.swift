import AppKit
import ArclightCore
import SwiftUI
import simd

/// One canvas drag: what it grabbed at mouse-down and how pointer movement maps to edits.
/// Every transform drag is wrapped in `beginGesture/endGesture` (one undo step).
final class GizmoSession: ObservableObject {
    enum Mode: Equatable {
        case none, move, scale(Handle), rotate, anchor(compensate: Bool), marquee(additive: Bool)
        case move3D, orbitPending, orbit, pan
    }

    // Published feedback drawn by the overlay.
    @Published var marquee: CGRect?  // canvas px
    @Published var snapLines: [SnapLine] = []
    @Published var readout: String?
    @Published var readoutAt = CGPoint.zero  // canvas-view points
    @Published var mode = Mode.none

    struct Item {
        let node: EvalNode
        let rect: CGRect  // canvas AABB at start
        let pivot: CGPoint  // canvas pivot at start
        let scale: (Double, Double)
        let scaleArray: Bool
    }

    var items: [Item] = []
    var nodes: [EvalNode] = []
    var startC = CGPoint.zero, startView = CGPoint.zero, startMouse = CGPoint.zero
    var box0 = CGRect.zero
    var toUnscaled = matrix_identity_float4x4  // canvas → single layer's rotated, unscaled frame at its pivot
    var worldInv = matrix_identity_float4x4
    var snapX: [CGFloat] = [], snapY: [CGFloat] = []
    var plane: Float = 0, hit0 = SIMD3<Float>(repeating: 0), pos0 = SIMD3<Float>(repeating: 0)
    var eye0 = SIMD3<Float>(repeating: 0), target0 = SIMD3<Float>(repeating: 0)
    var pan0 = CGSize.zero
    /// Press timing: edits only start once the press is clearly a drag (tap-to-click never nudges a layer).
    var press = PressTracker()
    /// Layer clicked at mouse-down (for "click a layer of a multi-selection selects just it").
    var clicked: String?
    var clickAdditive = false

    var isActive: Bool { mode != .none }

    static var mods: NSEvent.ModifierFlags { NSEvent.modifierFlags }
    static var spaceDown: Bool { CGEventSource.keyState(.combinedSessionState, key: 49) }
    static var mouse: CGPoint { let m = NSEvent.mouseLocation; return CGPoint(x: m.x, y: -m.y) }

    // MARK: Begin

    func begin(at v: CGPoint, doc: EditorDocument, vp: ViewportState, nodes: [EvalNode], layout: GizmoLayout) {
        let s = vp.scale
        let c = ViewZoom.canvasPoint(v, scale: s)
        let m = Self.mods
        self.nodes = nodes
        startC = c; startView = v; startMouse = Self.mouse
        press.begin(); clicked = nil; clickAdditive = m.contains(.shift)
        endEditing()

        if Self.spaceDown {
            // Space-drag pans. The global key handler toggles playback on Space; keep the viewer still.
            doc.playing = false
            pan0 = vp.pan; mode = .pan
            return
        }
        if m.contains(.option), doc.canOrbitCamera {
            mode = .orbitPending
            return
        }
        if let n = layout.single, !doc.isLocked(n.node.id) {
            if layout.onRotate(v) { startSingle(n, doc: doc, mode: .rotate); return }
            if let h = layout.handle(at: v) { startSingle(n, doc: doc, mode: .scale(h)); return }
            if layout.onPivot(v) { startSingle(n, doc: doc, mode: .anchor(compensate: m.contains(.option))); return }
        } else if layout.multi, let h = layout.handle(at: v) {
            startItems(doc.movable2D(nodes), doc: doc)
            box0 = items.map(\.rect).reduce(items.first?.rect ?? .zero) { $0.union($1) }
            mode = .scale(h); doc.beginGesture()
            return
        }
        if let n = hit(c, doc: doc, pickBackgrounds: m.contains(.option)) {
            let id = n.node.id
            clicked = id
            if m.contains(.shift) {
                doc.toggleCanvasSelection(id)
                guard doc.selectedIds.contains(id) else { mode = .none; return }
            } else if !doc.selectedIds.contains(id) {
                doc.multiSelection = []
                doc.selection = id
            } else if doc.selection != id, doc.multiSelection.contains(id) {
                // Keep the group; make the grabbed layer primary.
                var extra = doc.multiSelection; extra.remove(id)
                if let p = doc.selection { extra.insert(p) }
                doc.multiSelection = extra; doc.selection = id
            }
            startItems(doc.movable2D(nodes), doc: doc)
            guard !items.isEmpty else { mode = .none; return }
            snapTargets(doc, excluding: Set(items.map(\.node.node.id)))
            mode = .move; doc.beginGesture()
            return
        }
        if !m.contains(.shift), let id = doc.selected3D, let n = nodes.first(where: { $0.node.id == id }) {
            plane = n.world.columns.3.y
            if let h = doc.floorPoint(c, planeY: plane) {
                hit0 = h
                pos0 = SIMD3(Float(n.num("x", 0)), Float(n.num("y", 0)), Float(n.num("z", 0)))
                items = [Item(node: n, rect: .zero, pivot: .zero, scale: (1, 1), scaleArray: false)]
                mode = .move3D; doc.beginGesture()
                return
            }
        }
        mode = .marquee(additive: m.contains(.shift))
    }

    private func startItems(_ ns: [EvalNode], doc: EditorDocument) {
        items = ns.compactMap { n in
            guard let r = doc.canvasRect(n) else { return nil }
            let sc = n.props["scale"]
            return Item(
                node: n, rect: r, pivot: doc.pivot(n), scale: TransformMath.scaleParts(sc),
                scaleArray: (sc?.doubles?.count ?? 0) >= 2)
        }
    }

    private func startSingle(_ n: EvalNode, doc: EditorDocument, mode md: Mode) {
        startItems([n], doc: doc)
        guard let it = items.first else { return }
        // world = M0 · S · T(−anchor)  ⇒  M0 = world · T(anchor) · S⁻¹
        let a = n.anchor
        let sx = abs(it.scale.0) < 1e-6 ? 1e-6 : it.scale.0, sy = abs(it.scale.1) < 1e-6 ? 1e-6 : it.scale.1
        let m0 = n.world * M.translate(Float(a.x), Float(a.y), 0) * M.scale(Float(1 / sx), Float(1 / sy), 1)
        toUnscaled = m0.inverse
        worldInv = n.world.inverse
        snapTargets(doc, excluding: [n.node.id])
        mode = md
        doc.beginGesture()
    }

    private func snapTargets(_ doc: EditorDocument, excluding ids: Set<String>) {
        let others = nodes.filter { !$0.is3D && !ids.contains($0.node.id) && !doc.isFullFrame($0) }.compactMap {
            doc.canvasRect($0)
        }
        (snapX, snapY) = Snap.targets(canvas: doc.canvasSize, others: others)
    }

    /// Topmost pickable 2D layer under a canvas point.
    func hit(_ c: CGPoint, doc: EditorDocument, pickBackgrounds: Bool, in list: [EvalNode]? = nil) -> EvalNode? {
        for n in (list ?? nodes).reversed() where !n.is3D && !doc.isLocked(n.node.id) {
            guard let b = doc.renderer.localBounds(n) else { continue }
            // Full-frame layers (backgrounds, gradients) are only picked with ⌥, so clicking empty canvas deselects.
            if !pickBackgrounds && doc.isFullFrame(n) { continue }
            let l = n.world.inverse * SIMD4<Float>(Float(c.x), Float(c.y), 0, 1)
            if b.insetBy(dx: -4, dy: -4).contains(CGPoint(x: CGFloat(l.x), y: CGFloat(l.y))) { return n }
        }
        return nil
    }

    // MARK: End

    /// Returns true when the press was a click (never became a drag).
    @discardableResult
    func end(doc: EditorDocument) -> Bool {
        let wasClick = press.end()
        switch mode {
        case .move:
            doc.endGesture()
            // Click (no drag) on a layer of a multi-selection: select just that layer.
            if wasClick, !clickAdditive, let id = clicked, !doc.multiSelection.isEmpty {
                doc.multiSelection = []; doc.selection = id
            }
        case .scale, .rotate, .anchor, .move3D, .orbit: doc.endGesture()
        case .marquee(let additive):
            if let r = marquee, r.width * r.height > 4 {
                selectInside(r, additive: additive, doc: doc)
            } else if !additive {
                doc.multiSelection = []; doc.selection = nil
            }
        case .orbitPending:
            // ⌥-click without a drag: pick (backgrounds included) like before.
            if let n = hit(startC, doc: doc, pickBackgrounds: true) {
                doc.multiSelection = []; doc.selection = n.node.id
            } else {
                doc.multiSelection = []; doc.selection = nil
            }
        case .pan, .none: break
        }
        mode = .none
        marquee = nil; snapLines = []; readout = nil
        items = []; nodes = []
        return wasClick
    }

    private func selectInside(_ r: CGRect, additive: Bool, doc: EditorDocument) {
        let hits = nodes.filter { n in
            !n.is3D && !doc.isLocked(n.node.id) && !doc.isFullFrame(n) && (doc.canvasRect(n)?.intersects(r) ?? false)
        }.map(\.node.id)
        let ids = Set(LayerTree.topLevel(doc.scene, Set(hits)))
        var all = additive ? doc.selectedIds.union(ids) : ids
        let primary = hits.last { ids.contains($0) } ?? (additive ? doc.selection : nil)
        if let p = primary { all.remove(p) }
        doc.multiSelection = all
        doc.selection = primary
    }
}
