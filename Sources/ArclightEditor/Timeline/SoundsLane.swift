import AppKit
import ArclightCore
import SwiftUI

/// Left column of the sounds lane: how many clips, mute all, remove all.
struct SoundsLaneHeader: View {
    @ObservedObject var doc: EditorDocument

    var body: some View {
        let sounds = doc.scene.sounds ?? []
        let missing = sounds.filter { doc.soundClip($0) == nil }.count
        let allMuted = !sounds.isEmpty && sounds.allSatisfy { $0.mute == true }
        HStack(spacing: 6) {
            Image(systemName: missing > 0 ? "exclamationmark.triangle" : "speaker.badge.exclamationmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(missing > 0 ? UI.warning : UI.dim).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sounds").font(UI.small).foregroundStyle(UI.text)
                Text(missing > 0 ? "\(missing) file\(missing == 1 ? "" : "s") not found" : "\(sounds.count) clip\(sounds.count == 1 ? "" : "s")")
                    .font(UI.monoSmall).foregroundStyle(UI.faint).lineLimit(1)
            }
            Spacer(minLength: 2)
            IconButton(
                symbol: allMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                help: allMuted ? "All sounds muted. Click to unmute." : "Mute all sounds (editor playback and export)",
                active: allMuted
            ) {
                doc.editSounds { list in for i in list.indices { list[i].mute = allMuted ? nil : true } }
            }
            IconButton(symbol: "xmark", help: "Remove every sound clip from the scene (the files stay in assets)") {
                doc.apply([["op": "scene", "sounds": .array([])]])
            }
        }
        .padding(.leading, 12).padding(.trailing, 6)
        .frame(height: TL.soundsH)
        .background(UI.raised.opacity(0.5))
        .help("Sound effects and extra clips mixed over the scene audio. Drag a clip to move it; right-click for more.")
    }
}

/// Sound clips on one lane: small waveform boxes at their times (overlapping clips share the lane in two rows).
/// Drag a clip to move it; right-click for mute, gain and remove; click empty space to move the playhead.
struct SoundsLane: View {
    @ObservedObject var doc: EditorDocument
    let width: CGFloat

    @State private var dragId: String?
    @State private var baseOffset = 0.0
    @State private var press = PressTracker()
    @State private var scrubbing = false
    @State private var hoverId: String?
    @State private var loads = 0

    private static let pad: CGFloat = 3

    /// Clips with their row (0 or 1) so overlapping ones don't cover each other.
    private func layout(_ map: TimeMap) -> [(ref: AudioRef, clip: AudioClip, peaks: [Float]?, row: Int)] {
        var out: [(AudioRef, AudioClip, [Float]?, Int)] = []
        var rowEnd = [-Double.infinity, -Double.infinity]
        for r in doc.scene.sounds ?? [] {
            guard let (c, e) = doc.soundClip(r, onLoad: { loads += 1 }) else { continue }
            let row = c.start >= rowEnd[0] ? 0 : (c.start >= rowEnd[1] ? 1 : 0)
            rowEnd[row] = max(rowEnd[row], c.end)
            out.append((r, c, e.peaks, row))
        }
        return out
    }

    private static func box(_ c: AudioClip, row: Int, rows: Int, _ map: TimeMap, height: CGFloat) -> CGRect {
        let h = (height - pad * 2) / CGFloat(rows)
        let a = map.x(c.start), b = map.x(c.end)
        return CGRect(x: a, y: pad + CGFloat(row) * h, width: max(b - a, 3), height: h - (rows > 1 ? 1 : 0))
    }

    var body: some View {
        let map = TimeMap(doc: doc, width: width)
        let items = layout(map)
        let rows = items.contains { $0.row == 1 } ? 2 : 1
        Canvas { ctx, size in
            _ = loads
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(UI.raised.opacity(0.35)))
            for it in items {
                let b = Self.box(it.clip, row: it.row, rows: rows, map, height: size.height)
                draw(ctx, it.ref, it.clip, it.peaks, b, selected: it.ref.id == dragId || it.ref.id == hoverId)
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
        .frame(width: width, height: TL.soundsH)
        .clipped()
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            guard dragId == nil else { return }
            if case .active(let p) = phase { hoverId = hit(p, items, rows, map)?.id } else { hoverId = nil }
        }
        .cursor(hoverId != nil ? .openHand : .arrow)
        .contextMenu {
            if let id = hoverId, let r = doc.scene.sound(id) {
                Text("\(id) — \((r.src as NSString).lastPathComponent)")
                Button(r.mute == true ? "Unmute" : "Mute") {
                    doc.apply([["op": "sound", "id": .string(id), "mute": r.mute == true ? .null : true]])
                }
                Menu("Volume") {
                    ForEach([2.0, 1.4, 1, 0.7, 0.5, 0.25], id: \.self) { g in
                        Button(AudioClip.dB(g)) {
                            doc.apply([["op": "sound", "id": .string(id), "gain": g == 1 ? .null : .number(g)]])
                        }
                    }
                }
                Button("Move to Playhead") {
                    doc.apply([["op": "sound", "id": .string(id), "offset": .number(doc.time)]])
                }
                Divider()
                Button("Remove") { doc.apply([["op": "sound", "id": .string(id), "remove": true]]) }
            } else {
                Text("Right-click a clip for options")
            }
        }
        .help("Sound clips: drag to move · right-click for volume, mute and remove · click empty space to move the playhead")
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in changed(g, items, rows, map) }
                .onEnded { _ in ended() })
    }

    private func hit(_ p: CGPoint, _ items: [(ref: AudioRef, clip: AudioClip, peaks: [Float]?, row: Int)], _ rows: Int, _ map: TimeMap)
        -> AudioRef?
    {
        items.last { Self.box($0.clip, row: $0.row, rows: rows, map, height: TL.soundsH).insetBy(dx: -3, dy: 0).contains(p) }?.ref
    }

    private func changed(_ g: DragGesture.Value, _ items: [(ref: AudioRef, clip: AudioClip, peaks: [Float]?, row: Int)], _ rows: Int, _ map: TimeMap) {
        let tol = map.snapTolerance
        if dragId == nil && !scrubbing {
            press.begin()
            if let r = hit(g.startLocation, items, rows, map), let id = r.id {
                dragId = id
                baseOffset = r.offset ?? 0
                doc.beginGesture()
            } else {
                scrubbing = true
                doc.scrub(to: map.t(g.location.x), tolerance: tol)
            }
            return
        }
        press.update(g.translation)
        if scrubbing {
            doc.time = doc.clampedTime(doc.snapTime(map.t(g.location.x), tolerance: tol))
            return
        }
        guard press.dragging, let id = dragId else { return }
        let dt = Double(g.translation.width / map.pps)
        let s = doc.snapTime(baseOffset + dt, tolerance: tol, exclude: [baseOffset])
        let v = (s * 1000).rounded() / 1000
        doc.editSounds { list in
            if let i = list.firstIndex(where: { $0.id == id }) { list[i].offset = abs(v) < 1e-9 ? nil : v }
        }
    }

    private func ended() {
        let moved = press.dragging
        _ = press.end()
        if let id = dragId {
            doc.endGesture()
            if moved, let r = doc.scene.sound(id) {
                doc.flash("\(id) at \(fmt(r.offset ?? 0))s")
            } else if !moved {
                doc.playing = false
                doc.time = doc.clampedTime(doc.scene.sound(id)?.offset ?? doc.time)
            }
        }
        dragId = nil; scrubbing = false
    }

    private func draw(_ ctx: GraphicsContext, _ ref: AudioRef, _ c: AudioClip, _ peaks: [Float]?, _ box: CGRect, selected: Bool) {
        let muted = ref.mute == true
        ctx.fill(Path(roundedRect: box, cornerRadius: 3), with: .color(muted ? UI.field : UI.raised))
        if let peaks, !peaks.isEmpty, c.fileDuration > 0, box.width > 4 {
            var wave = Path()
            let mid = box.midY, half = box.height / 2 - 1
            var x = floor(max(0, box.minX))
            let n = Double(peaks.count)
            let map = TimeMap.Linear(x0: box.minX, t0: c.start, pps: box.width / max(1e-6, c.end - c.start))
            while x < box.maxX {
                let fa = c.filePosition(at: map.t(x)), fb = c.filePosition(at: map.t(x + 1))
                let ia = max(0, Int(fa / c.fileDuration * n)), ib = min(peaks.count - 1, Int(fb / c.fileDuration * n))
                if ia <= ib, ia < peaks.count {
                    var pk: Float = 0
                    for i in ia...ib { pk = max(pk, peaks[i]) }
                    let env = c.envelope(at: map.t(x + 0.5))
                    let h = min(half, CGFloat(Double(pk) * min(env, 2)) * half)
                    if h > 0.25 { wave.addRect(CGRect(x: x, y: mid - h, width: 1, height: h * 2)) }
                }
                x += 1
            }
            ctx.fill(wave, with: .color(muted ? UI.faint : UI.dim))
        }
        ctx.stroke(
            Path(roundedRect: box, cornerRadius: 3), with: .color(selected ? UI.text.opacity(0.8) : UI.fieldBorder),
            lineWidth: 1)
        if box.width > 24 {
            ctx.draw(
                Text(ref.id ?? (ref.src as NSString).lastPathComponent).font(.system(size: 9, weight: .medium))
                    .foregroundColor(UI.label2),
                at: CGPoint(x: max(box.minX, 0) + 4, y: box.minY + 6), anchor: .leading)
        }
    }
}

extension TimeMap {
    /// A plain x ↔ t line (inside one clip box).
    struct Linear {
        let x0: CGFloat, t0: Double, pps: CGFloat
        func t(_ x: CGFloat) -> Double { t0 + Double((x - x0) / pps) }
    }
}

extension EditorDocument {
    /// A sound's placement, or nil when its file can't be read.
    func soundClip(_ r: AudioRef, onLoad: @escaping () -> Void = {}) -> (AudioClip, AudioFileCache.Entry)? {
        guard let e = AudioFileCache.shared.entry(SceneAudio.url(r, assets: assets), onLoad: onLoad) else { return nil }
        return (AudioClip(r, fileDuration: e.info.duration, sceneDuration: scene.duration), e)
    }

    /// Changes the sound list in one undoable edit.
    func editSounds(_ change: (inout [AudioRef]) -> Void) {
        edit { s in
            var list = s.sounds ?? []
            change(&list)
            s.sounds = list.isEmpty ? nil : list
        }
    }

    /// Adds a file from assets/ as a sound clip at the playhead.
    func addSound(_ name: String, at t: Double? = nil) {
        let id = SceneOps.uniqueSoundId(name, in: scene.sounds ?? [])
        apply([["op": "sound", "id": .string(id), "src": .string(name), "offset": .number(((t ?? time) * 1000).rounded() / 1000)]])
        flash("Sound \(id) at \(fmt(t ?? time))s")
    }

    /// "Sound…": imports a sound file and adds it as a clip at the playhead.
    func importSound() {
        guard let u = FilePicker.files([.audio], message: "Choose a sound effect").first else { return }
        do {
            let name = try store.importAsset(from: u)
            guard SceneAudio.info(SceneAudio.url(AudioRef(src: name), assets: assets)) != nil else {
                flash("Can't read \(name) as audio"); return
            }
            addSound(name)
        } catch { flash("Could not import the sound: \(error.localizedDescription)") }
    }
}
