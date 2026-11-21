import AppKit
import ArclightCore
import SwiftUI

struct TLRow: Identifiable {
    let node: Node
    let prop: String?
    let depth: Int
    var id: String { prop.map { "\(node.id).\($0)" } ?? node.id }
}

enum TL {
    static let nameW: CGFloat = 250
    /// Layer row height, shared by names and tracks so they align: the density's (compact 26 / detailed 44) until
    /// ⇧ + scroll over the rows sets one of its own.
    static var rowH: CGFloat {
        let v = Pref.store.double(forKey: Pref.layerRowHeight)
        return v > 0 ? clamp(CGFloat(v), rowRange).rounded() : LayerDensity.current.rowHeight
    }
    static let rowRange: ClosedRange<CGFloat> = 22...120
    /// Ruler: a marker band on top, time labels and ticks below.
    static let rulerH: CGFloat = 34
    static let markerBandH: CGFloat = 14
    /// Reference-audio lane under the ruler (persisted; ⇧ + scroll over it changes it).
    static var audioH: CGFloat { laneHeight(Pref.audioLaneHeight, default: 46) }
    /// Height of one row of the sound-clips lane under the audio lane (persisted; ⇧ + scroll over it changes it).
    static var soundsRowH: CGFloat { laneHeight(Pref.soundsLaneHeight, default: 34) }
    /// The whole sound-clips lane: one row per stack of overlapping clips.
    static func soundsH(rows: Int) -> CGFloat { soundsRowH * CGFloat(max(rows, 1)) + 4 }
    static let laneRange: ClosedRange<CGFloat> = 28...240

    private static func clamp(_ v: CGFloat, _ r: ClosedRange<CGFloat>) -> CGFloat {
        min(max(v, r.lowerBound), r.upperBound)
    }

    private static func laneHeight(_ key: String, default d: CGFloat) -> CGFloat {
        let v = Pref.store.double(forKey: key)
        return v > 0 ? clamp(CGFloat(v), laneRange).rounded() : d
    }

    /// Grows / shrinks the layer rows (`Pref.layerRowHeight`) or a lane by `delta` points, kept in range. The
    /// unrounded height is stored so small trackpad steps add up. Tall rows switch the list to detailed (thumbnails).
    static func resize(_ key: String, by delta: CGFloat) {
        let row = key == Pref.layerRowHeight
        let stored = Pref.store.double(forKey: key)
        let now = stored > 0 ? CGFloat(stored) : row ? rowH : key == Pref.audioLaneHeight ? audioH : soundsRowH
        let h = clamp(now + delta, row ? rowRange : laneRange)
        guard h != now else { return }
        Pref.store.set(Double(h), forKey: key)
        if row {
            let d = (h.rounded() >= 36 ? LayerDensity.detailed : .compact).rawValue
            if Pref.store.string(forKey: Pref.layerDensity) != d { Pref.store.set(d, forKey: Pref.layerDensity) }
        }
    }

    /// Keyframe times (scene seconds) shown on a row.
    static func keyTimes(_ r: TLRow) -> [Double] {
        let start = r.node.start ?? 0
        let props = r.prop.map { [$0] } ?? Array(r.node.props.keys)
        var ts = Set<Double>()
        for k in props {
            if case .keys(let ks)? = r.node.props[k] {
                for kf in ks { ts.insert(((start + kf.t) * 1000).rounded() / 1000) }
            }
        }
        return ts.sorted()
    }
}

/// Maps between scene time and track x for the current zoom/offset. The one mapping used by the ruler, audio lane,
/// tracks and the scroll/zoom monitor, so playhead, ticks, markers, keys and bar edges always share an x.
/// A small left inset keeps 0 s (its tick, keys and the playhead) fully visible instead of half-clipped.
struct TimeMap {
    static let inset: CGFloat = 8
    let offset: Double, pps: CGFloat
    init(doc: EditorDocument, width: CGFloat) {
        offset = doc.tlOffset
        pps = max(width - Self.inset, 1) / CGFloat(max(doc.tlVisible, 0.01))
    }
    func x(_ t: Double) -> CGFloat { Self.inset + CGFloat(t - offset) * pps }
    func t(_ x: CGFloat) -> Double { offset + Double((x - Self.inset) / pps) }
    /// Snap distance in seconds: 6 points at this zoom.
    var snapTolerance: Double { Double(6 / pps) }
}

struct TimelineView: View {
    let doc: EditorDocument
    @State private var scroll = TimelineScrollMonitor()
    @AppStorage(Pref.layerDensity) private var density = LayerDensity.detailed.rawValue
    @AppStorage(Pref.audioLaneHeight) private var audioLaneH = 0.0
    @AppStorage(Pref.soundsLaneHeight) private var soundsLaneH = 0.0
    @AppStorage(Pref.layerRowHeight) private var rowHeight = 0.0

    var body: some View {
        let rows = doc.layerRows()
        let soundsH = TL.soundsH(rows: doc.soundRowCount)
        VStack(spacing: 0) {
            TransportBar(doc: doc)
            Hairline()
            GeometryReader { geo in
                let trackW = max(geo.size.width - TL.nameW - 1, 50)
                // The lanes scroll with the rows (a tall lane must not push the layers out of reach); the rows
                // area still fills what is left of the panel, so the space below the last row is clickable.
                let viewH = max(geo.size.height - TL.rulerH - 1, 60)
                let lanesH =
                    (doc.scene.audio != nil ? TL.audioH + 1 : 0)
                    + (doc.scene.sounds?.isEmpty == false ? soundsH + 1 : 0)
                let rowsH = max(viewH - lanesH, 60)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        LayerListHeader(doc: doc)
                        Hairline(vertical: true)
                        Ruler(doc: doc, width: trackW)
                    }
                    .frame(height: TL.rulerH)
                    Hairline()
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            if doc.scene.audio != nil {
                                HStack(spacing: 0) {
                                    AudioLaneHeader(doc: doc).frame(width: TL.nameW)
                                    Hairline(vertical: true)
                                    AudioLane(doc: doc, width: trackW)
                                }
                                .frame(height: TL.audioH)
                                .reportsLane(Pref.audioLaneHeight, to: scroll)
                                Hairline()
                            }
                            if doc.scene.sounds?.isEmpty == false {
                                HStack(spacing: 0) {
                                    SoundsLaneHeader(doc: doc).frame(width: TL.nameW)
                                    Hairline(vertical: true)
                                    SoundsLane(doc: doc, width: trackW)
                                }
                                .frame(height: soundsH)
                                .reportsLane(Pref.soundsLaneHeight, to: scroll)
                                Hairline()
                            }
                            HStack(alignment: .top, spacing: 0) {
                                NamesColumn(doc: doc, rows: rows).frame(width: TL.nameW, alignment: .top)
                                    .frame(minHeight: rowsH, alignment: .top)
                                Hairline(vertical: true)
                                Tracks(doc: doc, rows: rows, width: trackW, minHeight: rowsH, viewportHeight: viewH)
                            }
                            .frame(minHeight: max(CGFloat(rows.count) * TL.rowH, rowsH), alignment: .top)
                        }
                    }
                    // A legacy (always-visible) scroller would take width and shift the tracks against the ruler.
                    .scrollIndicators(.never)
                    .overlay(alignment: .center) { EmptyTimelineNote(doc: doc).allowsHitTesting(false) }
                }
                .onAppear { scroll.attach(doc) }
                .onChange(of: doc.scene) { _, s in  // drop selected keys that no longer exist (undo, reload, deletes)
                    let ui = doc.timelineUI
                    let k = KeyEdit.existing(s, ui.selectedKeys)
                    if k != ui.selectedKeys { ui.selectedKeys = k }
                }
                .onDisappear { scroll.detach() }
                .onChange(of: geo.frame(in: .global), initial: true) { _, f in
                    scroll.region = f
                    scroll.trackX = f.minX + TL.nameW + 1
                    scroll.trackW = trackW
                }
            }
        }
        .background(UI.panel)
    }
}

extension View {
    /// Keeps `monitor.lanes[key]` at this lane's window frame (for ⇧ + scroll over it).
    func reportsLane(_ key: String, to monitor: TimelineScrollMonitor) -> some View {
        background(
            GeometryReader { g in
                Color.clear
                    .onChange(of: g.frame(in: .global), initial: true) { _, f in monitor.lanes[key] = f }
                    .onDisappear { monitor.lanes[key] = nil }
            })
    }
}

/// What to do when the scene has no layers yet (or the filter hides them all).
private struct EmptyTimelineNote: View {
    let doc: EditorDocument

    var body: some View {
        let filter = doc.layerUI.filter
        if doc.scene.nodes.isEmpty {
            VStack(spacing: 4) {
                Text("No layers yet").font(UI.font.weight(.medium)).foregroundStyle(UI.label2)
                Text("Click + Layer (top right of the timeline), drag images or audio onto the viewer, or ask the AI.")
                    .font(UI.small).foregroundStyle(UI.dim).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24).padding(.top, 70)
        } else if !filter.isEmpty, !doc.scene.nodes.contains(where: { LayerTree.matches($0, filter) }) {
            Text("No layers match “\(filter)”").font(UI.small).foregroundStyle(UI.dim).padding(.top, 70)
        }
    }
}
