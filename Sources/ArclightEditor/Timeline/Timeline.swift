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
    /// Follows the layer list density (compact 26 / detailed 44) so names and tracks align.
    static var rowH: CGFloat { LayerDensity.current.rowHeight }
    /// Ruler: a marker band on top, time labels and ticks below.
    static let rulerH: CGFloat = 34
    static let markerBandH: CGFloat = 14
    /// Reference-audio lane under the ruler.
    static let audioH: CGFloat = 46

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
    @ObservedObject var doc: EditorDocument
    @StateObject private var scroll = TimelineScrollMonitor()
    @AppStorage(Pref.layerDensity) private var density = LayerDensity.detailed.rawValue

    var body: some View {
        let rows = doc.layerRows()
        VStack(spacing: 0) {
            TransportBar(doc: doc)
            Hairline()
            GeometryReader { geo in
                let trackW = max(geo.size.width - TL.nameW - 1, 50)
                // Rows area fills the panel, so the empty space below the last row is clickable / box-selectable.
                let rowsH = max(geo.size.height - TL.rulerH - 1 - (doc.scene.audio != nil ? TL.audioH + 1 : 0), 60)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        LayerListHeader(doc: doc)
                        Hairline(vertical: true)
                        Ruler(doc: doc, width: trackW)
                    }
                    .frame(height: TL.rulerH)
                    Hairline()
                    if doc.scene.audio != nil {
                        HStack(spacing: 0) {
                            AudioLaneHeader(doc: doc).frame(width: TL.nameW)
                            Hairline(vertical: true)
                            AudioLane(doc: doc, width: trackW)
                        }
                        .frame(height: TL.audioH)
                        Hairline()
                    }
                    ScrollView(.vertical) {
                        HStack(alignment: .top, spacing: 0) {
                            NamesColumn(doc: doc, rows: rows).frame(width: TL.nameW, alignment: .top)
                                .frame(minHeight: rowsH, alignment: .top)
                            Hairline(vertical: true)
                            Tracks(doc: doc, rows: rows, width: trackW, minHeight: rowsH)
                        }
                        .frame(minHeight: max(CGFloat(rows.count) * TL.rowH, rowsH), alignment: .top)
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

/// What to do when the scene has no layers yet (or the filter hides them all).
private struct EmptyTimelineNote: View {
    @ObservedObject var doc: EditorDocument

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
