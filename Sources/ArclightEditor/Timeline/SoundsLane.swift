import AppKit
import ArclightCore
import SwiftUI

/// Left column of the sounds lane: how many clips, mute all, remove all.
struct SoundsLaneHeader: View {
    let doc: EditorDocument
    @AppStorage(Pref.soundsLaneHeight) private var laneH = 0.0  // redraw when ⇧ + scroll resizes the lane

    var body: some View {
        let sounds = doc.scene.sounds ?? []
        let missing = sounds.count - doc.soundRows().count
        let allMuted = !sounds.isEmpty && sounds.allSatisfy { $0.mute == true }
        let rows = doc.soundRowCount
        HStack(spacing: 6) {
            Image(systemName: missing > 0 ? "exclamationmark.triangle" : "speaker.badge.exclamationmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(missing > 0 ? UI.warning : UI.dim).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sounds").font(UI.small).foregroundStyle(UI.text)
                Text(missing > 0 ? "\(missing) file\(missing == 1 ? "" : "s") not found" : "\(sounds.count) clip\(sounds.count == 1 ? "" : "s")" + (rows > 1 ? " · \(rows) rows" : ""))
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
        .frame(height: TL.soundsRowH + 4)
        .frame(height: TL.soundsH(rows: rows), alignment: .top)
        .background(UI.raised.opacity(0.5))
        .help("Sound effects and extra clips mixed over the scene audio. Drag a clip to move it; right-click for more.")
    }
}

/// Sound clips: small waveform boxes at their times, each overlapping clip on a row of its own (the lane grows).
/// Drag a clip to move it; right-click for mute, gain and remove; click empty space to move the playhead.
struct SoundsLane: View {
    let doc: EditorDocument
    let width: CGFloat
    @AppStorage(Pref.soundsLaneHeight) private var laneH = 0.0  // redraw when ⇧ + scroll resizes the lane

    @State private var dragId: String?
    @State private var baseOffset = 0.0
    @State private var press = PressTracker()
    @State private var scrubbing = false
    @State private var hoverId: String?
    @State private var loads = 0

    private static let pad: CGFloat = 3

    private static func box(_ c: AudioClip, row: Int, _ map: TimeMap) -> CGRect {
        let h = TL.soundsRowH
        let a = map.x(c.start), b = map.x(c.end)
        return CGRect(x: a, y: pad + CGFloat(row) * h, width: max(b - a, 3), height: h - 2)
    }

    var body: some View {
        let map = TimeMap(doc: doc, width: width)
        let items = doc.soundRows(onLoad: { loads += 1 })
        let rows = (items.map(\.row).max() ?? 0) + 1
        Canvas { ctx, size in
            _ = loads
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(UI.raised.opacity(0.35)))
            for it in items {
                let b = Self.box(it.clip, row: it.row, map)
                draw(
                    ctx, it.ref, it.clip, it.peaks, b, selected: it.ref.id == dragId || it.ref.id == hoverId,
                    picked: it.ref.id != nil && it.ref.id == doc.selectedSound)
            }
            let ex = map.x(doc.scene.duration)
            TimelineInk.drawPastEnd(ctx, size, endX: ex)
            TimelineInk.drawEndLine(ctx, size, endX: ex)
            for m in doc.scene.markers ?? [] {
                ctx.fill(
                    Path(TimelineInk.lineRect(map.x(m.t), width: 1, height: size.height)),
                    with: .color(MarkerStyle.color(m).opacity(0.3)))
            }
        }
        .frame(width: width, height: TL.soundsH(rows: rows))
        .onReceive(NotificationCenter.default.publisher(for: AudioFileCache.loaded)) { _ in loads += 1 }
        .overlay(TimelineInk.Playhead(clock: doc.clock, map: map))
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
        .help(
            "Sound clips: click to select (Delete removes it) · drag to move · right-click for volume, mute and remove · click empty space to move the playhead"
        )
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in changed(g, items, rows, map) }
                .onEnded { _ in ended() })
    }

    private func hit(_ p: CGPoint, _ items: [EditorDocument.SoundRow], _ rows: Int, _ map: TimeMap) -> AudioRef? {
        items.last { Self.box($0.clip, row: $0.row, map).insetBy(dx: -3, dy: -1).contains(p) }?.ref
    }

    private func changed(_ g: DragGesture.Value, _ items: [EditorDocument.SoundRow], _ rows: Int, _ map: TimeMap) {
        let tol = map.snapTolerance
        if dragId == nil && !scrubbing {
            press.begin()
            if let r = hit(g.startLocation, items, rows, map), let id = r.id {
                dragId = id
                baseOffset = r.offset ?? 0
                doc.beginGesture()
            } else {
                scrubbing = true
                doc.selectedSound = nil
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
                // A click picks the clip (Delete removes it); the playhead stays where it is.
                doc.selection = nil
                doc.multiSelection = []
                doc.selectedSound = id
            }
        }
        dragId = nil; scrubbing = false
    }

    private func draw(
        _ ctx: GraphicsContext, _ ref: AudioRef, _ c: AudioClip, _ peaks: [Float]?, _ box: CGRect, selected: Bool,
        picked: Bool = false
    ) {
        let muted = ref.mute == true
        ctx.fill(
            Path(roundedRect: box, cornerRadius: 3),
            with: .color(picked ? UI.accent.opacity(0.28) : (muted ? UI.field : UI.raised)))
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
            Path(roundedRect: box, cornerRadius: 3),
            with: .color(picked ? UI.accent : (selected ? UI.text.opacity(0.8) : UI.fieldBorder)),
            lineWidth: picked ? 1.5 : 1)
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
    struct SoundRow { let ref: AudioRef; let clip: AudioClip; let peaks: [Float]?; let row: Int }

    /// Sound clips with their row: sorted by start, each on the first row that is free by then, so no two clips
    /// on a row overlap. Clips whose file can't be read are left out.
    func soundRows(onLoad: @escaping () -> Void = {}) -> [SoundRow] {
        let key = LaneMemo.key(scene.sounds ?? [], duration: scene.duration, assets: assets)
        if let m = laneMemo.sounds[scene.id], m.key == key { return m.value }
        let rows = buildSoundRows(onLoad: onLoad)
        if laneMemo.sounds.count > 16 { laneMemo.sounds.removeAll() }
        laneMemo.sounds[scene.id] = (key, rows)
        return rows
    }

    private func buildSoundRows(onLoad: @escaping () -> Void) -> [SoundRow] {
        var placed: [(AudioRef, AudioClip, AudioFileCache.Entry)] = []
        for r in scene.sounds ?? [] {
            if let (c, e) = soundClip(r, onLoad: onLoad) { placed.append((r, c, e)) }
        }
        let order = placed.indices.sorted { (placed[$0].1.start, $0) < (placed[$1].1.start, $1) }
        var rowEnd: [Double] = []
        var rowOf = [Int](repeating: 0, count: placed.count)
        for i in order {
            let c = placed[i].1
            let row = rowEnd.firstIndex { c.start >= $0 - 1e-6 } ?? rowEnd.count
            if row == rowEnd.count { rowEnd.append(c.end) } else { rowEnd[row] = c.end }
            rowOf[i] = row
        }
        // List order keeps the draw / hit order the user knows (later clips on top).
        return placed.indices.map { SoundRow(ref: placed[$0].0, clip: placed[$0].1, peaks: placed[$0].2.peaks, row: rowOf[$0]) }
    }

    /// How many rows the sounds lane needs (at least 1).
    var soundRowCount: Int { (soundRows().map(\.row).max() ?? 0) + 1 }

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
