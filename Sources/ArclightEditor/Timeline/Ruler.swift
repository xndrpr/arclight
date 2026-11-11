import AppKit
import ArclightCore
import SwiftUI

/// Time ruler. Click or drag to scrub (also past END, where the viewer holds the last frame); drag the END tab to
/// change the duration (snaps to keys, markers, the playhead); markers live in the band on top (drag to move,
/// double-click to rename, right-click for colour / delete / expression); ⌥-drag sets the work area
/// (⌥-click clears it). The ruler keeps counting past END; that area is hatched (not rendered).
struct Ruler: View {
    @ObservedObject var doc: EditorDocument
    let width: CGFloat

    enum Drag: Equatable { case scrub, end, marker(String, Double), work(Double) }
    @State var drag: Drag?
    @State private var press = PressTracker()
    private var moved: Bool { press.dragging }
    @State var hoverEnd = false
    @State var hoverMarker: String?
    @State var renaming: String?
    @State private var renameText = ""
    @State private var lastClick: (name: String, at: Date)?
    @FocusState private var renameFocused: Bool

    var body: some View {
        let map = TimeMap(doc: doc, width: width)
        let d = doc.scene.duration
        Canvas { ctx, size in
            drawRuler(ctx, size, map)
            if let w = doc.workArea { drawWorkArea(ctx, size, map, w) }
            drawEnd(ctx, size, map, d)
            drawMarkers(ctx, size, map)
            let px = map.x(doc.time)
            TimelineInk.drawPlayhead(ctx, size, x: px)
            var head = Path()
            head.move(to: CGPoint(x: px - 5, y: TL.markerBandH));
            head.addLine(to: CGPoint(x: px + 5, y: TL.markerBandH))
            head.addLine(to: CGPoint(x: px, y: TL.markerBandH + 6))
            ctx.fill(head, with: .color(TimelineInk.playhead))
        }
        .frame(width: width, height: TL.rulerH)
        .overlay(alignment: .topLeading) { renameField(map) }
        .clipped()
        .contentShape(Rectangle())
        .onContinuousHover { p in
            if case .active(let pt) = p {
                let m = markerHit(pt, map)
                if m != hoverMarker { hoverMarker = m }
                let e = m == nil && endHit(pt, map, d)
                if e != hoverEnd { hoverEnd = e }
            } else {
                hoverEnd = false; hoverMarker = nil
            }
        }
        .cursor(hoverMarker != nil ? .openHand : .resizeLeftRight)
        .help(help(d))
        .contextMenu { menu() }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in changed(g, map, d) }
                .onEnded { _ in ended() })
    }

    static let endFont = Font.system(size: 8.5, weight: .bold)

    // MARK: Hit testing

    private func markerHit(_ p: CGPoint, _ map: TimeMap) -> String? {
        guard p.y <= TL.markerBandH + 2 else { return nil }
        let ms = doc.scene.markers ?? []
        // Flag spans from the line to the right; prefer the closest line.
        return ms.filter { p.x >= map.x($0.t) - 4 && p.x <= map.x($0.t) + 40 }
            .min { abs(map.x($0.t) - p.x) < abs(map.x($1.t) - p.x) }?.name
    }

    private func endHit(_ p: CGPoint, _ map: TimeMap, _ d: Double) -> Bool {
        let ex = map.x(d)
        return p.x >= ex - 4 && p.x <= ex + 30 && p.y > TL.markerBandH - 2
    }

    private func help(_ d: Double) -> String {
        if let m = hoverMarker, let mk = doc.scene.marker(m) {
            return
                "\(m) at \(fmt((mk.t * 1000).rounded() / 1000))s — drag to move, double-click to rename, right-click for more. Expressions: \(MarkerEdit.expression(m))"
        }
        if hoverEnd {
            return "Scene end (\(fmt(d))s) — drag to change the duration; it snaps to keys, markers and the playhead"
        }
        return
            "Click or drag to move the playhead (past END the viewer shows the last frame) · drag END to change the length · ⌥-drag sets the loop work area · M adds a marker"
    }

    // MARK: Gestures

    private func changed(_ g: DragGesture.Value, _ map: TimeMap, _ d: Double) {
        let tol = map.snapTolerance
        let t = map.t(g.location.x)
        if drag == nil {
            endEditing()
            commitRename()
            press.begin()
            let t0 = map.t(g.startLocation.x)
            if NSEvent.modifierFlags.contains(.option) {
                drag = .work(doc.snapTime(t0, tolerance: tol))
            } else if let m = markerHit(g.startLocation, map), let mk = doc.scene.marker(m) {
                drag = .marker(m, mk.t); doc.beginGesture()
            } else if endHit(g.startLocation, map, d) {
                drag = .end; doc.beginGesture()
            } else {
                drag = .scrub
            }
            doc.playing = false
        }
        press.update(g.translation)
        switch drag! {
        case .scrub:
            doc.time = doc.clampedTime(doc.snapTime(t, tolerance: tol))
        case .end:
            guard moved else { return }
            doc.setDuration(doc.snapTime(t, tolerance: tol, exclude: [d]))
        case .marker(let name, let t0):
            guard moved, let m = doc.scene.marker(name) else { return }
            let nt = max(
                0, doc.snapTime(t0 + Double(g.translation.width / map.pps), tolerance: tol, exclude: [t0, m.t]))
            if nt != m.t { doc.updateMarker(name, t: nt) }
        case .work(let a):
            guard moved else { return }
            let b = max(0, doc.snapTime(t, tolerance: tol))
            if abs(b - a) >= 1 / doc.fps { doc.workArea = min(a, b)...max(a, b) }
        }
    }

    private func ended() {
        let wasDrag = moved
        _ = press.end()
        switch drag {
        case .end?:
            doc.endGesture()
            if wasDrag { doc.flash("Duration \(fmt(doc.scene.duration))s") } else { doc.time = doc.scene.duration }
        case .marker(let name, _)?:
            doc.endGesture()
            if !wasDrag {
                // Click: playhead to the marker; second click on the same marker renames it.
                if let lc = lastClick, lc.name == name, Date().timeIntervalSince(lc.at) < NSEvent.doubleClickInterval {
                    startRename(name); lastClick = nil
                } else {
                    lastClick = (name, Date())
                    if let m = doc.scene.marker(name) { doc.time = doc.clampedTime(m.t) }
                }
            }
        case .work?:
            if !wasDrag {
                doc.workArea = nil; doc.flash("Work area cleared")
            } else if let w = doc.workArea {
                doc.flash(
                    "Work area \(fmt((w.lowerBound * 100).rounded() / 100))–\(fmt((w.upperBound * 100).rounded() / 100))s"
                )
            }
        default: break
        }
        drag = nil
    }

    // MARK: Rename

    private func startRename(_ name: String) {
        renameText = name
        renaming = name
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        guard let old = renaming else { return }
        renaming = nil
        let n = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !n.isEmpty, n != old { doc.updateMarker(old, rename: n) }
    }

    @ViewBuilder private func renameField(_ map: TimeMap) -> some View {
        if let name = renaming, let m = doc.scene.marker(name) {
            TextField("Marker name", text: $renameText)
                .textFieldStyle(.plain).font(MarkerStyle.font).foregroundStyle(UI.text)
                .focused($renameFocused)
                .onSubmit { commitRename() }
                .onExitCommand { renaming = nil }
                .onChange(of: renameFocused) { _, f in if !f { commitRename() } }
                .padding(.horizontal, 4).frame(width: 140, height: TL.markerBandH + 2)
                .background(RoundedRectangle(cornerRadius: 3).fill(UI.field))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(MarkerStyle.color(m), lineWidth: 1))
                .offset(x: min(max(0, map.x(m.t)), max(0, width - 140)), y: 0)
        }
    }

    // MARK: Context menu

    @ViewBuilder private func menu() -> some View {
        if let name = hoverMarker, let m = doc.scene.marker(name) {
            Button("Rename…") { startRename(name) }
            Menu("Colour") {
                ForEach(MarkerEdit.colors, id: \.hex) { c in
                    Button(c.name) { doc.updateMarker(name, color: .some(c.hex)) }
                }
                Divider()
                Button("Default") { doc.updateMarker(name, color: .some(nil)) }.disabled(m.color == nil)
            }
            Button("Copy \(MarkerEdit.expression(name))") {
                let pb = NSPasteboard.general
                pb.clearContents(); pb.setString(MarkerEdit.expression(name), forType: .string)
                doc.flash("Copied \(MarkerEdit.expression(name))")
            }
            Button("Move Playhead Here") { doc.time = doc.clampedTime(m.t) }
            Divider()
            Button("Delete Marker") { doc.removeMarker(name) }
        } else {
            Button("Add Marker at Playhead (M)") { doc.addMarkerAtPlayhead() }
            Divider()
            Button(doc.loopEnabled ? "Turn Loop Off (⌘L)" : "Turn Loop On (⌘L)") { doc.toggleLoop() }
            Button("Clear Work Area") { doc.workArea = nil }.disabled(doc.workArea == nil)
        }
    }
}
