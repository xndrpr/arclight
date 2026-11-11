import AppKit
import ArclightCore
import SwiftUI
import UniformTypeIdentifiers

/// Per-document timeline state that isn't scene data: selected keyframes, copied keys, whether the timeline
/// was the last thing clicked (so ⌫ / ⌥← → act on keys), and one-time warnings.
final class TimelineUIState: ObservableObject {
    @Published var selectedKeys: Set<KeyRef> = []
    var clipboard: KeyEdit.Clip?
    /// True after a click in the timeline tracks / ruler, false after a click anywhere else in the window.
    var focused = false
    /// Layers we already warned about (expressions can't follow a trimmed start).
    var warnedExpr: Set<String> = []
}

private let timelineUIStates = NSMapTable<EditorDocument, TimelineUIState>.weakToStrongObjects()

extension EditorDocument {
    var timelineUI: TimelineUIState {
        if let s = timelineUIStates.object(forKey: self) { return s }
        let s = TimelineUIState()
        timelineUIStates.setObject(s, forKey: self)
        return s
    }

    /// Keys the keyboard acts on: selected keys while the timeline has focus.
    private var activeKeys: Set<KeyRef>? {
        let ui = timelineUI
        guard ui.focused else { return nil }
        let k = KeyEdit.existing(scene, ui.selectedKeys)
        return k.isEmpty ? nil : k
    }

    // MARK: Keyframes

    /// ⌫ in the timeline: deletes the selected keys. Returns false when there are none (delete the layer instead).
    func deleteSelectedKeys() -> Bool {
        guard let keys = activeKeys else { return false }
        edit { $0 = KeyEdit.delete($0, keys) }
        timelineUI.selectedKeys = []
        flash(keys.count == 1 ? "Deleted keyframe" : "Deleted \(keys.count) keyframes")
        return true
    }

    /// ⌥← / ⌥→: nudges the selected keys by frames. Returns false when there are none.
    func nudgeSelectedKeys(_ frames: Int) -> Bool {
        guard let keys = activeKeys else { return false }
        let r = KeyEdit.move(scene, keys, by: Double(frames) / fps)
        edit { $0 = r.scene }
        timelineUI.selectedKeys = r.refs
        return true
    }

    func setEase(_ keys: Set<KeyRef>, _ name: String) {
        edit { $0 = KeyEdit.setEase($0, keys, name == "linear" ? nil : Easing(name)) }
    }

    func copyKeys(_ keys: Set<KeyRef>) {
        guard let c = KeyEdit.copy(scene, keys) else { return }
        timelineUI.clipboard = c
        flash(c.items.count == 1 ? "Copied keyframe" : "Copied \(c.items.count) keyframes")
    }

    /// Pastes copied keys at the playhead: onto the selected layer when a single other layer is selected, else
    /// back onto the layers they came from.
    func pasteKeys() {
        guard let c = timelineUI.clipboard else { return }
        let sources = Set(c.items.map(\.node))
        let target = selection.flatMap { sel in
            scene.node(sel) != nil && !sources.contains(sel) && sources.count == 1 ? sel : nil
        }
        let r = KeyEdit.paste(scene, c, at: (time * fps).rounded() / fps, target: target)
        guard !r.refs.isEmpty else { flash("Nothing to paste onto"); return }
        edit { $0 = r.scene }
        timelineUI.selectedKeys = r.refs
    }

    // MARK: Markers

    /// M: adds "marker-N" at the playhead.
    func addMarkerAtPlayhead() {
        let t = (time * fps).rounded() / fps
        if let m = scene.markers?.first(where: { abs($0.t - t) < 0.5 / fps }) {
            flash("\(m.name) is already here"); return
        }
        let name = MarkerEdit.nextName(scene)
        apply([MarkerEdit.addOp(name, t: t)])
        flash("Added \(name) at \(fmt(t))s")
    }

    func updateMarker(_ name: String, rename: String? = nil, t: Double? = nil, color: String?? = nil) {
        guard let m = scene.marker(name) else { return }
        if let r = rename, r != name, scene.marker(r) != nil { flash("A marker named \(r) already exists"); return }
        apply(MarkerEdit.updateOps(m, name: rename, t: t, color: color))
    }

    func removeMarker(_ name: String) { apply([MarkerEdit.removeOp(name)]) }

    // MARK: Loop / work area

    /// ⌘L: loop playback on / off.
    func toggleLoop() {
        loopEnabled.toggle()
        flash(loopEnabled ? (workArea != nil ? "Loop work area" : "Loop on") : "Loop off")
    }

    // MARK: Audio

    /// "Audio…": imports a sound file into the project's assets and makes it the scene's reference audio.
    func importAudio() {
        guard let u = FilePicker.files([.audio], message: "Choose a voiceover or music file").first else { return }
        do {
            let name = try store.importAsset(from: u)
            guard SceneAudio.info(SceneAudio.url(AudioRef(src: name), assets: assets)) != nil else {
                flash("Can't read \(name) as audio"); return
            }
            apply([["op": "scene", "audio": ["src": .string(name)]]])
            flash("Audio: \(name)")
        } catch { flash("Could not import audio: \(error.localizedDescription)") }
    }

    func setAudio(_ change: (inout AudioRef) -> Void) {
        edit { s in
            guard var a = s.audio else { return }
            change(&a)
            s.audio = a
        }
    }

    func removeAudio() { apply([["op": "scene", "audio": .null]]) }
}
