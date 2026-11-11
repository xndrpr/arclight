import AppKit
import ArclightCore
import SwiftUI

/// Left column of the audio lane: file name, gain, mute, remove.
struct AudioLaneHeader: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        let a = doc.scene.audio
        let missing = doc.audioClip() == nil
        HStack(spacing: 6) {
            Image(systemName: missing ? "exclamationmark.triangle" : "waveform").font(
                .system(size: 11, weight: .medium)
            )
            .foregroundStyle(missing ? UI.warning : UI.dim).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(a.map { ($0.src as NSString).lastPathComponent } ?? "").font(UI.small).foregroundStyle(UI.text)
                    .lineLimit(1).truncationMode(.middle)
                Text(missing ? "File not found" : "Audio · \(AudioClip.dB(a?.gain ?? 1))").font(UI.monoSmall)
                    .foregroundStyle(UI.faint).lineLimit(1)
            }
            Spacer(minLength: 2)
            let muted = a?.mute == true
            IconButton(
                symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                help: muted
                    ? "Muted — silent in the editor and left out of exports. Click to unmute."
                    : "Mute (editor playback and export)",
                active: muted
            ) {
                doc.setAudio { $0.mute = $0.mute == true ? nil : true }
            }
            IconButton(symbol: "xmark", help: "Remove audio from the scene (the file stays in assets)") {
                doc.removeAudio()
            }
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: TL.audioH)
        .background(UI.raised.opacity(0.5))
        .help(
            a.map { "\($0.src) — the scene's reference audio. Drag the clip to move it; drag the line for volume." }
                ?? "")
    }
}

/// The audio clip on the timeline: waveform, gain line, fades. Drag the body to move it (offset), the left edge
/// to trim the head, the right edge to set where it stops (the scene end), the gain line up/down, and the
/// fade handles (knees on the gain line) sideways.
struct AudioLane: View {
    @ObservedObject var doc: EditorDocument
    let width: CGFloat

    private enum Hit: Equatable { case none, body, trimIn, end, gain, fadeIn, fadeOut }
    @State private var drag: Hit?
    @State private var base: AudioRef?
    @State private var baseClip: AudioClip?
    @State private var press = PressTracker()
    @State private var pressT = 0.0
    private var moved: Bool { press.dragging }
    @State private var hoverCursor = NSCursor.arrow
    @State private var loads = 0

    private static let pad: CGFloat = 4

    var body: some View {
        let map = TimeMap(doc: doc, width: width)
        let c = doc.audioClip { loads += 1 }
        Canvas { ctx, size in
            _ = loads
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(UI.raised.opacity(0.35)))
            if let c {
                AudioLaneDrawing(clip: c.clip, ref: c.ref, peaks: c.entry.peaks, map: map, gainLabel: drag == .gain)
                    .draw(ctx, size)
            }
            let ex = map.x(doc.scene.duration)
            TimelineInk.drawPastEnd(ctx, size, endX: ex)
            TimelineInk.drawEndLine(ctx, size, endX: ex)
            for m in doc.scene.markers ?? [] {
                ctx.fill(
                    Path(TimelineInk.lineRect(map.x(m.t), width: 1, height: size.height)),
                    with: .color(MarkerStyle.color(m).opacity(0.3)))
            }
            TimelineInk.drawPlayhead(ctx, size, x: map.x(doc.time))
        }
        .frame(width: width, height: TL.audioH)
        .clipped()
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard drag == nil else { return }
            var cur = NSCursor.arrow
            if case .active(let p) = phase, let c {
                switch hit(p, c.clip, map) {
                case .body: cur = .openHand
                case .trimIn, .end, .fadeIn, .fadeOut: cur = .resizeLeftRight
                case .gain: cur = .resizeUpDown
                case .none: cur = .arrow
                }
            }
            if cur != hoverCursor { hoverCursor = cur }
        }
        .cursor(hoverCursor)
        .help(
            "Audio clip: drag to move · drag the left edge to trim · drag the line up/down for volume · drag the round knobs for fades · click empty space to move the playhead"
        )
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in changed(g, map) }
                .onEnded { _ in ended() })
    }

    static func box(_ c: AudioClip, _ map: TimeMap, height: CGFloat) -> CGRect {
        let a = map.x(c.start), b = map.x(c.end)
        return CGRect(x: a, y: pad, width: max(b - a, 2), height: height - pad * 2)
    }

    static func gainY(_ g: Double, height: CGFloat) -> CGFloat {
        let h = height - pad * 2
        return pad + h - CGFloat(AudioClip.unitY(gain: g)) * h
    }

    private func hit(_ p: CGPoint, _ c: AudioClip, _ map: TimeMap) -> Hit {
        let b = Self.box(c, map, height: TL.audioH)
        guard p.x >= b.minX - 6, p.x <= b.maxX + 6 else { return .none }
        let gy = Self.gainY(c.gain, height: TL.audioH)
        let fiX = map.x(c.audibleStart + c.fadeIn),
            foX = map.x(max(c.audibleStart, min(c.audibleEnd, c.sceneDuration - c.fadeOut)))
        if abs(p.y - gy) < 7 {
            if abs(p.x - fiX) < 6 { return .fadeIn }
            if abs(p.x - foX) < 6 { return .fadeOut }
        }
        if abs(p.x - b.minX) < 5 { return .trimIn }
        if abs(p.x - map.x(c.audibleEnd)) < 5 { return .end }
        if abs(p.y - gy) < 4 { return .gain }
        return p.x >= b.minX && p.x <= b.maxX ? .body : .none
    }

    private func changed(_ g: DragGesture.Value, _ map: TimeMap) {
        let tol = map.snapTolerance
        if drag == nil {
            endEditing()
            press.begin()
            pressT = doc.snapTime(map.t(g.startLocation.x), tolerance: tol)
            guard let c = doc.audioClip() else { drag = Hit.none; return }
            let h = hit(g.startLocation, c.clip, map)
            drag = h
            if h == .none {
                doc.scrub(to: map.t(g.location.x), tolerance: tol)
                return
            }
            base = c.ref; baseClip = c.clip
            doc.beginGesture()
            if h == .body { hoverCursor = .closedHand }
            return
        }
        press.update(g.translation)
        let t = map.t(g.location.x)
        guard base != nil, let c = baseClip else {
            if drag == Hit.none { doc.time = doc.clampedTime(doc.snapTime(t, tolerance: tol)) }
            return
        }
        guard moved else { return }
        let dt = Double(g.translation.width / map.pps)
        switch drag! {
        case .none: break
        case .body:
            let s = doc.snapTime(c.start + dt, tolerance: tol, exclude: [c.start])
            doc.setAudio { $0.offset = AudioLane.clean(c.moved(to: s).offset) }
        case .trimIn:
            let r = c.trimmedStart(to: doc.snapTime(t, tolerance: tol, exclude: [c.start]))
            doc.setAudio {
                $0.offset = AudioLane.clean(r.offset); $0.trim = AudioLane.clean(r.trim)
            }
        case .end:
            let e = min(c.end, max(1 / doc.fps, doc.snapTime(t, tolerance: tol, exclude: [doc.scene.duration])))
            doc.setDuration(e)
        case .gain:
            let h = TL.audioH - Self.pad * 2
            let y0 = Self.gainY(c.gain, height: TL.audioH) + g.translation.height
            var gain = AudioClip.gain(fromUnitY: Double((Self.pad + h - y0) / h))
            if abs(gain - 1) < 0.03 { gain = 1 }  // detent at 0 dB
            gain = (gain * 100).rounded() / 100
            doc.setAudio { $0.gain = gain == 1 ? nil : gain }
        case .fadeIn:
            let f = min(max(0, t - c.audibleStart), c.audibleEnd - c.audibleStart)
            let v = (f * doc.fps).rounded() / doc.fps
            doc.setAudio { $0.fadeIn = v < 1e-6 ? nil : v }
        case .fadeOut:
            let f = min(max(0, c.sceneDuration - t), c.sceneDuration - c.audibleStart)
            let v = (f * doc.fps).rounded() / doc.fps
            doc.setAudio { $0.fadeOut = v < 1e-6 ? nil : v }
        }
    }

    private func ended() {
        let wasDrag = moved
        _ = press.end()
        if base != nil {
            doc.endGesture()
            if !wasDrag, drag == .body {
                // A click on the clip (no drag) moves the playhead there, like empty space.
                doc.playing = false
                doc.time = doc.clampedTime(pressT)
            }
            if wasDrag, let a = doc.scene.audio {
                switch drag {
                case .gain?: doc.flash("Audio gain \(AudioClip.dB(a.gain ?? 1))")
                case .body?, .trimIn?:
                    doc.flash(
                        "Audio at \(fmt(((a.offset ?? 0) * 1000).rounded() / 1000))s, trim \(fmt(((a.trim ?? 0) * 1000).rounded() / 1000))s"
                    )
                case .end?: doc.flash("Duration \(fmt(doc.scene.duration))s")
                default: break
                }
            }
        }
        drag = nil; base = nil; baseClip = nil
        hoverCursor = .arrow
    }

    private static func clean(_ x: Double) -> Double? {
        let r = (x * 1e6).rounded() / 1e6; return abs(r) < 1e-9 ? nil : r
    }
}
