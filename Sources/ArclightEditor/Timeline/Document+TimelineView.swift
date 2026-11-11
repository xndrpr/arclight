import ArclightCore
import QuartzCore

extension EditorDocument {
    // MARK: Timeline view (zoom / pan)

    /// Zoom relative to "fit" (1 = everything fits), for display.
    var tlZoom: Double { fitSpan() / tlVisible }

    /// Hard bound for panning and the playhead: practically endless (hours past any scene).
    static let timelineLimit: Double = 6 * 3600

    /// Last rendered frame; the viewer, gizmos and thumbnails show it while the playhead is past END.
    var lastFrameTime: Double { SceneExtent.lastFrame(scene.duration, fps: fps) }
    /// Time the viewer shows: the playhead, held at the last frame past END.
    var viewTime: Double { min(time, lastFrameTime) }
    var isPastEnd: Bool { time > lastFrameTime + 0.5 / fps }

    /// Latest point anything happens: scene end, layer out points, last keyframe.
    var contentEnd: Double {
        var e = scene.duration
        for n in scene.nodes {
            let st = n.start ?? 0
            if let o = n.end { e = max(e, o) }
            for p in n.props.values { if case .keys(let ks) = p, let last = ks.last { e = max(e, st + last.t) } }
        }
        return e
    }

    /// Scene plus breathing room after the end.
    func fitSpan() -> Double { let e = contentEnd; return e + max(2, e * 0.25) }

    /// How far right you can pan: no practical limit (past END the ruler keeps counting, shaded).
    var panLimit: Double { Self.timelineLimit }

    /// Furthest the playhead may go (past the scene end; the viewer then holds the last frame).
    var maxTime: Double { Self.timelineLimit }

    /// Zoom-out bound: a few times "everything fits" (at least a minute), so the scale never degenerates.
    var maxVisible: Double { min(max(fitSpan() * 4, 60), panLimit) }

    func zoomTimeline(by f: Double, anchor: Double? = nil) {
        let a = anchor ?? time
        let minVisible = 12 / fps  // ~12 frames across = frame-level detail
        let v = min(max(tlVisible / f, minVisible), maxVisible)
        let frac = (a - tlOffset) / tlVisible
        tlVisible = v
        setTimelineOffset(a - frac * v)
    }

    /// Pans (never left of 0, practically unbounded to the right). Never changes the scale.
    func setTimelineOffset(_ o: Double) {
        tlOffset = min(max(0, o), max(0, panLimit - tlVisible))
    }

    /// ⇧Z / the zoom label: everything fits. Eases over ~0.2 s unless reduced motion is on or it's playing.
    func zoomToFit(animated: Bool = true) {
        let v = fitSpan()
        zoomTween?.invalidate(); zoomTween = nil
        guard animated, !Motion.reduce, !playing, abs(v - tlVisible) + tlOffset > 1e-6 else {
            tlVisible = v; tlOffset = 0; return
        }
        let v0 = tlVisible, o0 = tlOffset, start = CACurrentMediaTime(), dur = 0.22
        zoomTween = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let k = min(1, (CACurrentMediaTime() - start) / dur), e = 1 - pow(1 - k, 3)
            self.tlVisible = v0 + (v - v0) * e
            self.tlOffset = o0 * (1 - e)
            if k >= 1 { t.invalidate(); self.zoomTween = nil }
        }
    }

    /// Sets the scene length (dragging END, the inspector). Content past the new END stays, shaded.
    func setDuration(_ d: Double) {
        let v = max(1 / fps, (d * fps).rounded() / fps)
        edit(grow: false) { $0.duration = v }
    }

    func followPlayhead() {
        if time < tlOffset || time > tlOffset + tlVisible { setTimelineOffset(time - tlVisible * 0.1) }
    }

    // MARK: Keyframe navigation

    /// Scene times of keyframes (and layer in/out points when `includeEdges`) for a layer/prop, or all layers.
    func keyTimes(node id: String?, prop: String? = nil, includeEdges: Bool = false) -> [Double] {
        var ts = Set<Double>()
        for n in scene.nodes where id == nil || n.id == id {
            let st = n.start ?? 0
            if includeEdges { ts.insert(st); if let e = n.end { ts.insert(e) } }
            for (k, p) in n.props where prop == nil || k == prop {
                if case .keys(let ks) = p { for kf in ks { ts.insert(((st + kf.t) * 1000).rounded() / 1000) } }
            }
        }
        if includeEdges { ts.insert(0); ts.insert(scene.duration); for m in scene.markers ?? [] { ts.insert(m.t) } }
        return ts.sorted()
    }

    /// Moves the playhead to the previous/next keyframe (of a prop, the selected layer, or edit points).
    func jumpKey(forward: Bool, node id: String?, prop: String? = nil) {
        let ts = keyTimes(node: id, prop: prop, includeEdges: prop == nil)
        let eps = 0.5 / fps
        let target = forward ? ts.first { $0 > time + eps } : ts.last { $0 < time - eps }
        if let t = target { playing = false; time = clampedTime(t); followPlayhead() }
    }

    /// Removes all keyframes of a prop, keeping the value at the playhead.
    func clearAnimation(_ id: String, _ prop: String) {
        guard let n = scene.node(id), let p = n.props[prop] else { return }
        let v = renderer.evaluator.value(p, t: time - (n.start ?? 0), T: time, duration: scene.duration)
        setRaw(id, prop, .value(v))
    }

    func clearAllAnimation(_ id: String) {
        guard let n = scene.node(id) else { return }
        edit { s in
            guard let i = s.nodes.firstIndex(where: { $0.id == id }) else { return }
            for (k, p) in n.props where p.isAnimated {
                if case .keys = p {
                    s.nodes[i].props[k] = .value(
                        renderer.evaluator.value(p, t: time - (n.start ?? 0), T: time, duration: s.duration))
                }
            }
        }
    }

    /// Snaps a time to frames and, when snapping is on, to the playhead and nearby keyframes/edges (within `tolerance` s).
    func snapTime(_ t: Double, tolerance: Double, exclude: Set<Double> = []) -> Double {
        var r = (t * fps).rounded() / fps
        guard snapping else { return r }
        let candidates = [time] + keyTimes(node: nil, includeEdges: true) + (scene.markers ?? []).map(\.t)
        if let best = candidates.filter({ !exclude.contains($0) }).min(by: { abs($0 - t) < abs($1 - t) }),
            abs(best - t) < tolerance
        {
            r = best
        }
        return r
    }
}
