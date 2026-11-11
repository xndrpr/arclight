import ArclightCore
import Foundation

/// The scene's END and what lies past it.
///
/// The timeline scrolls on past END without limit and the playhead may follow, but a scene has no frames after
/// its end: the viewer then shows the last frame. Nothing is created out there by accident: an editor edit that
/// puts a keyframe or a layer's in point past END (where it could never be seen) extends the scene to include it.
/// Out points past END are fine (the layer just runs to the end). Dragging END itself never auto-extends.
enum SceneExtent {
    /// Time of the last rendered frame (export renders frames 0 ..< ceil(duration × fps)).
    static func lastFrame(_ duration: Double, fps: Double) -> Double {
        max(0, ((duration * fps).rounded(.up) - 1) / fps)
    }

    /// Latest keyframe time and latest layer in point (scene seconds).
    static func latest(_ s: Scene) -> (key: Double, start: Double) {
        var key = 0.0, start = 0.0
        for n in s.nodes {
            let st = n.start ?? 0
            start = max(start, st)
            for p in n.props.values { if case .keys(let ks) = p, let last = ks.last { key = max(key, st + last.t) } }
        }
        return (key, start)
    }

    /// A key exactly at END is allowed (half a frame of tolerance); later ones are "past the end".
    static func isPast(_ t: Double, _ duration: Double, fps: Double) -> Bool { t > duration + 0.5 / fps }

    /// The duration `after` should get so an edit's new keys / in points stay inside the scene, or nil to leave it.
    /// Only edits that newly put something past END grow it; scenes that already had content out there (older
    /// files, or END dragged back on purpose) are left alone.
    static func grownDuration(before: Scene, after: Scene, fps: Double) -> Double? {
        let b = latest(before), a = latest(after)
        let wasOver = isPast(b.key, before.duration, fps: fps) || isPast(b.start, before.duration, fps: fps)
        guard !wasOver else { return nil }
        var d = after.duration
        if isPast(a.key, d, fps: fps) { d = (a.key * fps).rounded() / fps + 1 / fps }  // the key gets the last frame
        // a new layer gets a second
        if isPast(a.start, d, fps: fps) { d = max(d, (a.start * fps).rounded() / fps + 1) }
        return d > after.duration + 1e-9 ? d : nil
    }
}
