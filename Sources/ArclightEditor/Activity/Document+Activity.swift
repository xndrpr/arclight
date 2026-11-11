import ArclightCore
import CoreGraphics
import Foundation

extension EditorDocument {
    /// Shows a layer (and optionally a time) from the activity feed / notes, switching scene if needed.
    func reveal(scene sceneId: String?, layer: String?, time t: Double? = nil) {
        if let sceneId, sceneId != scene.id {
            guard store.scenes[sceneId] != nil else { flash("Scene \(sceneId) no longer exists"); return }
            open(scene: sceneId)
        }
        if let layer {
            if scene.node(layer) != nil {
                selection = layer; multiSelection = []
            } else {
                flash("\(layer) is no longer in this scene")
            }
        }
        if let t { playing = false; time = min(max(0, t), maxTime) }
    }

    /// Whether a layer still exists in a scene (the working copy for the open one).
    func layerExists(_ id: String, in sceneId: String?) -> Bool {
        let s = sceneId == nil || sceneId == scene.id ? scene : store.scenes[sceneId!]
        return s?.node(id) != nil
    }

    /// Restores `rev` of a scene as a new revision, opening that scene first.
    func restore(scene sceneId: String?, rev: Int) {
        if let sceneId, sceneId != scene.id {
            guard store.scenes[sceneId] != nil else { flash("Scene \(sceneId) no longer exists"); return }
            open(scene: sceneId)
        }
        restore(rev: rev)
    }

    /// Renders a scene at a time for small previews (history thumbnails, compare). Ignores solo.
    func preview(_ s: Scene, time t: Double, width: Double) -> CGImage? {
        let saved = (renderer.only, renderer.draft)
        renderer.only = nil; renderer.draft = true
        defer { renderer.only = saved.0; renderer.draft = saved.1 }
        let (cw, _) = project.size(for: s)
        let scale = max(0.02, min(1, width / Double(cw)))
        return try? renderer.image(scene: s, project: project, assets: assets, time: t, scale: scale)
    }
}
