import AppKit
import ArclightCore
import SwiftUI

/// Layer bars and keyframes.
///
/// - Diamond: click selects it (⇧/⌘-click adds or removes); drag moves every selected key; right-click for easing,
///   copy, paste, delete. A click without dragging also moves the playhead to the key.
/// - Bar: drag retimes the layer; left edge trims the start (content stays put); right edge sets the out point.
/// - Empty track space: drag scrubs. ⌥-drag anywhere (or drag in the empty area below the rows) draws a
///   selection box around keys; add ⇧ to add to the selection.
/// Moves snap to frames and (with Snap on) to the playhead, keys, edges and markers. A press only becomes a drag
/// once it clearly moves (`ClickSlop`), so trackpad tap-to-click always selects / places the playhead.
/// Past END: moving a key or a layer's start there extends the scene to include it (`SceneExtent`).
struct Tracks: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var ui: TimelineUIState
    let rows: [TLRow]
    let width: CGFloat
    var minHeight: CGFloat = 120

    init(doc: EditorDocument, rows: [TLRow], width: CGFloat, minHeight: CGFloat = 120) {
        self.doc = doc; self.ui = doc.timelineUI; self.rows = rows; self.width = width; self.minHeight = minHeight
    }

    private enum Hit: Equatable { case none, key(Int, Double), bar(Int), edgeIn(Int), edgeOut(Int) }
    private enum Drag {
        case scrub
        /// Click below the rows: becomes a box once it moves, else deselects and moves the playhead.
        case pendingBox
        case box(additive: Bool, base: Set<KeyRef>)
        /// `grab` = scene time of the grabbed diamond; `refs` = keys being moved; `onRelease` = selection if not dragged.
        case keys(grab: Double, refs: Set<KeyRef>, onRelease: Set<KeyRef>?)
        case shift(String), trimIn(String), trimOut(String)
    }
    @State private var drag: Drag?
    @State private var base: Scene?
    @State private var press = PressTracker()
    private var moved: Bool { press.dragging }
    @State private var box: CGRect?
    @State private var hoverCursor = NSCursor.arrow
    /// Keys under the pointer (for the right-click menu).
    @State private var hoverKeys: Set<KeyRef> = []

    var body: some View {
        let map = TimeMap(doc: doc, width: width)
        let d = doc.scene.duration
        Canvas { ctx, size in
            TrackDrawing(doc: doc, rows: rows, map: map, selected: ui.selectedKeys).draw(ctx, size)
            if let box {
                ctx.fill(Path(box), with: .color(TimelineInk.boxFill))
                ctx.stroke(
                    Path(box), with: .color(TimelineInk.boxStroke), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .frame(width: width, height: max(CGFloat(rows.count) * TL.rowH, minHeight))
        .clipped()
        .contentShape(Rectangle())
        .onContinuousHover { phase in hover(phase, map: map, d: d) }
        .cursor(hoverCursor)
        .contextMenu { KeyMenu(doc: doc, keys: menuKeys) }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in changed(g, map: map, d: d) }
                .onEnded { _ in ended() })
    }

    /// Right-click target: the whole selection when the key under the pointer is part of it, else that key.
    private var menuKeys: Set<KeyRef> {
        guard !hoverKeys.isEmpty else { return [] }
        return hoverKeys.isSubset(of: ui.selectedKeys) ? ui.selectedKeys : hoverKeys
    }

    // MARK: Hit testing

    private func hit(_ p: CGPoint, map: TimeMap, d: Double) -> Hit {
        let i = Int(floor(p.y / TL.rowH))
        guard i >= 0, i < rows.count else { return .none }
        let r = rows[i], t0 = map.t(p.x)
        if doc.isLocked(r.node.id) { return .none }  // locked layers (and camera/look rows) can't be edited
        let cy = CGFloat(i) * TL.rowH + TL.rowH / 2
        // Generous diamond target: ±7 pt sideways, most of the row height.
        if abs(p.y - cy) <= max(8, TL.rowH / 2 - 4), let k = TL.keyTimes(r).min(by: { abs($0 - t0) < abs($1 - t0) }),
            abs(map.x(k) - p.x) < 7
        {
            return .key(i, k)
        }
        guard r.prop == nil else { return .none }
        let a = map.x(r.node.start ?? 0), b = map.x(r.node.end ?? d)
        let nearIn = abs(a - p.x) < 5, nearOut = abs(b - p.x) < 5
        if nearIn && nearOut { return p.x < (a + b) / 2 ? .edgeIn(i) : .edgeOut(i) }
        if nearOut { return .edgeOut(i) }
        if nearIn { return .edgeIn(i) }
        return p.x >= a && p.x <= b ? .bar(i) : .none
    }

    private func refs(_ i: Int, _ k: Double) -> Set<KeyRef> {
        KeyEdit.refs(doc.scene, node: rows[i].node.id, prop: rows[i].prop, at: k)
    }

    private func hover(_ phase: HoverPhase, map: TimeMap, d: Double) {
        guard drag == nil else { return }
        var cursor = NSCursor.arrow
        var keys: Set<KeyRef> = []
        if case .active(let p) = phase {
            switch hit(p, map: map, d: d) {
            case .key(let i, let k): cursor = .pointingHand; keys = refs(i, k)
            case .edgeIn, .edgeOut: cursor = .resizeLeftRight
            case .bar: cursor = .openHand
            case .none: cursor = NSEvent.modifierFlags.contains(.option) ? .crosshair : .arrow
            }
        }
        if cursor != hoverCursor { hoverCursor = cursor }
        if keys != hoverKeys { hoverKeys = keys }
    }

    // MARK: Gestures

    private func begin(_ g: DragGesture.Value, map: TimeMap, d: Double, tol: Double) {
        endEditing()
        press.begin()
        let mods = NSEvent.modifierFlags
        let additive = mods.contains(.shift) || mods.contains(.command)
        let t0 = map.t(g.startLocation.x)
        let h = hit(g.startLocation, map: map, d: d)
        if case .key(let i, let k) = h {
            let hitKeys = refs(i, k)
            var release: Set<KeyRef>?
            if additive {
                if hitKeys.isSubset(of: ui.selectedKeys) {
                    release = ui.selectedKeys.subtracting(hitKeys)
                } else {
                    ui.selectedKeys.formUnion(hitKeys)
                }
            } else {
                if !hitKeys.isSubset(of: ui.selectedKeys) { ui.selectedKeys = hitKeys }
                release = hitKeys
            }
            drag = .keys(grab: k, refs: ui.selectedKeys, onRelease: release)
            hoverCursor = .closedHand
            base = doc.scene; doc.beginGesture()
            return
        }
        if mods.contains(.option) { drag = .box(additive: additive, base: additive ? ui.selectedKeys : []); return }
        if Int(floor(g.startLocation.y / TL.rowH)) >= rows.count { drag = .pendingBox; return }
        if !additive { ui.selectedKeys = [] }
        switch h {
        case .edgeIn(let i): drag = .trimIn(rows[i].node.id); doc.selection = rows[i].node.id
        case .edgeOut(let i): drag = .trimOut(rows[i].node.id); doc.selection = rows[i].node.id
        case .bar(let i): drag = .shift(rows[i].node.id); doc.selection = rows[i].node.id; hoverCursor = .closedHand
        default:
            drag = .scrub
            let i = Int(floor(g.startLocation.y / TL.rowH))
            if i >= 0, i < rows.count, rows[i].prop == nil { doc.selection = rows[i].node.id }
            doc.scrub(to: t0, tolerance: tol)
            return
        }
        base = doc.scene; doc.beginGesture()
    }

    private func changed(_ g: DragGesture.Value, map: TimeMap, d: Double) {
        let tol = map.snapTolerance
        if drag == nil { begin(g, map: map, d: d, tol: tol); return }
        press.update(g.translation)
        let t = map.t(g.location.x)
        switch drag! {
        case .scrub: doc.scrub(to: t, tolerance: tol)
        case .pendingBox:
            if moved {
                drag = .box(
                    additive: NSEvent.modifierFlags.contains(.shift),
                    base: NSEvent.modifierFlags.contains(.shift) ? ui.selectedKeys : [])
            }
        case .box(_, let start):
            let r = CGRect(
                x: min(g.startLocation.x, g.location.x), y: min(g.startLocation.y, g.location.y),
                width: abs(g.location.x - g.startLocation.x), height: abs(g.location.y - g.startLocation.y))
            box = r
            ui.selectedKeys = start.union(keys(in: r, map: map))
        case .shift(let id):
            guard moved, let base, let n = base.node(id) else { return }
            let st0 = n.start ?? 0
            let st = doc.snapTime(st0 + Double(g.translation.width / map.pps), tolerance: tol, exclude: [st0])
            let q = st - st0
            doc.edit { s in
                s = base
                guard let i = s.nodes.firstIndex(where: { $0.id == id }) else { return }
                s.nodes[i].start = abs(st) < 1e-9 ? nil : st
                if let e = base.nodes[i].end { s.nodes[i].end = e + q }
            }
        case .trimIn(let id):
            guard moved, let base, let n = base.node(id) else { return }
            let st0 = n.start ?? 0, e = n.end ?? base.duration
            let st = min(max(0, doc.snapTime(t, tolerance: tol, exclude: [st0])), e - 1 / doc.fps)
            let r = TimelineEdit.trimStart(base, id: id, to: st)
            doc.edit { $0 = r.scene }
            if r.usesExpressions, !ui.warnedExpr.contains(id) {
                ui.warnedExpr.insert(id)
                doc.flash(
                    "\(n.name ?? id) uses expressions — they keep timing relative to the layer start and don't shift with the trim"
                )
            }
        case .trimOut(let id):
            guard moved, let base, let n = base.node(id) else { return }
            let st = n.start ?? 0
            let e = max(st + 1 / doc.fps, doc.snapTime(t, tolerance: tol, exclude: [n.end ?? base.duration]))
            doc.edit { s in
                s = base
                guard let i = s.nodes.firstIndex(where: { $0.id == id }) else { return }
                s.nodes[i].end = e
            }
        case .keys(let k, let refs, _):
            guard moved, let base else { return }
            let exclude = Set(refs.map { ((KeyEdit.sceneTime(base, $0)) * 1000).rounded() / 1000 } + [k])
            let nk = doc.snapTime(k + Double(g.translation.width / map.pps), tolerance: tol, exclude: exclude)
            let r = KeyEdit.move(base, refs, by: nk - k)
            doc.edit { $0 = r.scene }
            ui.selectedKeys = r.refs
        }
    }

    private func ended() {
        switch drag {
        case .keys(let k, _, let release)? where !moved:
            if let release { ui.selectedKeys = release }
            doc.playing = false  // like scrubbing: the playhead stays on the clicked key
            doc.time = doc.clampedTime(k)
        case .pendingBox?:
            // Click below the rows: deselect everything and move the playhead there.
            doc.selection = nil
            ui.selectedKeys = []
        default: break
        }
        if base != nil { doc.endGesture() }
        _ = press.end()
        drag = nil; base = nil; box = nil
        hoverCursor = .arrow
    }

    /// Keys whose diamonds lie inside a box (track coordinates).
    private func keys(in r: CGRect, map: TimeMap) -> Set<KeyRef> {
        guard r.width > 0 || r.height > 0 else { return [] }
        let range = map.t(r.minX)...map.t(r.maxX)
        var out = Set<KeyRef>()
        for (i, row) in rows.enumerated() {
            let cy = CGFloat(i) * TL.rowH + TL.rowH / 2
            guard cy >= r.minY - 4, cy <= r.maxY + 4, !doc.isLocked(row.node.id) else { continue }
            out.formUnion(KeyEdit.refs(doc.scene, node: row.node.id, prop: row.prop, in: range))
        }
        return out
    }
}
