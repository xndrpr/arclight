import AppKit
import ArclightCore
import SwiftUI

struct TransportBar: View {
    @ObservedObject var doc: EditorDocument

    /// Narrow timelines step down (frame-step and zoom buttons go first; their shortcuts still work) rather than
    /// pushing the panel wider than the window.
    enum Density { case full, compact, tight }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(.full)
            bar(.compact)
            bar(.tight)
        }
        .padding(.horizontal, 8).frame(height: 36)
        .environment(\.barHitHeight, 36)  // buttons take clicks across the whole bar height
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .onAppear { AudioPlayback.attach(doc) }
    }

    private func bar(_ d: Density) -> some View {
        HStack(spacing: 4) {
            IconButton(symbol: "backward.end.fill", help: "Start (Home)") {
                doc.playing = false; doc.time = 0
            }
            if d == .full { IconButton(symbol: "chevron.left", help: "Previous frame (←)") { doc.step(-1) } }
            IconButton(
                symbol: doc.playing ? "pause.fill" : "play.fill", help: "Play / stop (Space)", active: doc.playing
            ) { doc.togglePlay() }
            if d == .full { IconButton(symbol: "chevron.right", help: "Next frame (→)") { doc.step(1) } }
            IconButton(symbol: "repeat", help: loopHelp, active: doc.loopEnabled) { doc.toggleLoop() }
            Text(timecode(doc.time)).font(UI.mono).foregroundStyle(UI.text).frame(width: 78, alignment: .leading)
                .padding(.leading, 6).fixedSize()
                .help("Playhead · ← → step frames, Home / End jump")
            // Secondary info steps down too (most important last to go).
            ViewThatFits(in: .horizontal) {
                info(duration: true, frame: true, chips: true)
                info(duration: true, frame: false, chips: true)
                info(duration: false, frame: false, chips: true)
                info(duration: false, frame: false, chips: false)
            }
            Spacer(minLength: 4)
            Button {
                doc.snapping.toggle()
            } label: {
                Text("Snap").font(UI.small).foregroundStyle(doc.snapping ? UI.text : UI.faint).fixedSize()
                    .padding(.horizontal, 7).frame(height: 22)
                    .background(RoundedRectangle(cornerRadius: 5).fill(doc.snapping ? UI.hover : .clear))
                    .barHit()
            }
            .buttonStyle(.plain).help("Snap to playhead, keyframes, layer edges and markers (N)").cursor(.pointingHand)
            Hairline(vertical: true).frame(height: 16).padding(.horizontal, d == .tight ? 1 : 4)
            if d != .tight {
                IconButton(symbol: "minus.magnifyingglass", help: "Zoom out (⌘−, ⌥ + scroll)") {
                    doc.zoomTimeline(by: 1 / 1.5)
                }
            }
            Button {
                doc.zoomToFit()
            } label: {
                Text(
                    abs(doc.tlZoom - 1) < 0.02 ? "Fit" : String(format: doc.tlZoom < 1 ? "%.1f×" : "%.0f×", doc.tlZoom)
                )
                .font(UI.monoSmall).foregroundStyle(UI.dim).frame(width: 34, height: 22).barHit()
            }
            .buttonStyle(.plain).help(
                "Timeline zoom — click to fit the whole scene (⇧Z). ⌥-scroll or pinch to zoom, scroll sideways to pan; it keeps going past END."
            ).cursor(.pointingHand)
            if d != .tight {
                IconButton(symbol: "plus.magnifyingglass", help: "Zoom in (⌘=, ⌥ + scroll, pinch)") {
                    doc.zoomTimeline(by: 1.5)
                }
            }
            Hairline(vertical: true).frame(height: 16).padding(.horizontal, d == .tight ? 1 : 4)
            AddLayerMenu(doc: doc)
        }
    }

    @ViewBuilder private func info(duration: Bool, frame: Bool, chips: Bool) -> some View {
        HStack(spacing: 6) {
            if duration {
                Text("/ " + timecode(doc.scene.duration)).font(UI.mono).foregroundStyle(UI.faint).fixedSize()
            }
            if frame {
                Text("f\(Int((doc.time * doc.fps).rounded()))").font(UI.monoSmall).foregroundStyle(UI.faint).fixedSize()
            }
            if doc.isPastEnd {
                Text(chips ? "PAST END" : "END+").font(.system(size: 8.5, weight: .bold)).tracking(0.5).foregroundStyle(
                    UI.warning
                )
                .padding(.horizontal, 5).frame(height: 16).fixedSize()
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(UI.warning.opacity(0.6), lineWidth: 1))
                .help(
                    "The playhead is after the scene's end: the viewer shows the last frame. Drag END on the ruler to make the scene longer."
                )
            }
            if doc.playing && doc.rate != 1 {
                Text(String(format: "%@%g×", doc.rate < 0 ? "◀︎ " : "", abs(doc.rate))).font(UI.monoSmall)
                    .foregroundStyle(UI.text).fixedSize()
            }
            if chips, let w = doc.workArea { WorkAreaChip(range: w) { doc.workArea = nil }.fixedSize() }
        }
    }

    private var loopHelp: String {
        let state = doc.loopEnabled ? "on" : "off — playback stops at the end"
        return "Loop \(state) (⌘L). ⌥-drag on the ruler to loop a work area."
    }

    private func timecode(_ t: Double) -> String {
        let s = Int(t), cs = Int(((t - Double(s)) * 100).rounded(.down))
        return String(format: "%02d:%02d.%02d", s / 60, s % 60, cs)
    }
}

/// Shows the work area range; × clears it.
private struct WorkAreaChip: View {
    let range: ClosedRange<Double>
    let clear: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "repeat").font(.system(size: 8, weight: .semibold)).foregroundStyle(UI.dim)
            Text("\(fmt((range.lowerBound * 100).rounded() / 100))–\(fmt((range.upperBound * 100).rounded() / 100))s")
                .font(UI.monoSmall).foregroundStyle(UI.label2)
            Button(action: clear) {
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold)).foregroundStyle(
                    hover ? UI.text : UI.dim
                )
                .frame(width: 14, height: 16).hitArea()
            }
            .buttonStyle(.plain).onHover { hover = $0 }.cursor(.pointingHand).help("Clear the work area")
        }
        .padding(.horizontal, 6).frame(height: 18)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(UI.border, lineWidth: 1))
        .help("Work area — playback loops inside it. ⌥-drag on the ruler to change, ⌥-click to clear.")
    }
}
