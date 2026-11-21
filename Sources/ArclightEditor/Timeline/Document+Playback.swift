import ArclightCore
import QuartzCore

extension EditorDocument {
    // MARK: Playback

    /// Advances the playhead in real time; called by the viewport each frame while playing.
    func tick() -> Double {
        guard playing else { return time }
        let now = CACurrentMediaTime()
        let step = PlaybackLoop.advance(
            playTime, by: (now - lastTick) * rate, duration: scene.duration, loop: loopEnabled, range: workArea)
        playTime = step.t
        lastTick = now
        if step.stop { playing = false; time = (playTime * fps).rounded() / fps; return playTime }
        if now - lastPublish > 1.0 / 30 {
            lastPublish = now
            ticking = true
            time = (playTime * fps).rounded(.down) / fps
            ticking = false
            followPlayhead()
        }
        return playTime
    }

    func togglePlay() {
        if playing { playing = false; time = (playTime * fps).rounded() / fps } else { rate = 1; playing = true }
    }

    /// J / L shuttle (Resolve): repeated presses double the speed up to 8×; K stops.
    func shuttle(_ dir: Double) {
        if dir == 0 { if playing { togglePlay() }; return }
        if playing && (rate > 0) == (dir > 0) {
            rate = max(-8, min(8, rate * 2))
        } else {
            rate = dir; if !playing { playing = true }
        }
        flash(String(format: "%@ %g×", rate < 0 ? "◀︎" : "▶︎", abs(rate)))
    }

    /// `t` limited to the timeline's playable range (0 ... `maxTime`).
    func clampedTime(_ t: Double) -> Double { min(max(0, t), maxTime) }

    /// Stops playback and puts the playhead at `t` (snapped, then clamped): a click or drag in the ruler, tracks or
    /// audio lanes. Like playback, each step moves only what follows the playhead live (the viewer, the playhead
    /// line, the timecode); the rest of the editor that shows the time (inspector values, layer thumbnails, history
    /// frames) catches up a few times a second and once the pointer rests. Redrawing all of it on every step made
    /// scrubbing stutter on big scenes.
    func scrub(to t: Double, tolerance: Double) {
        if playing { playing = false }
        ticking = true
        time = clampedTime(snapTime(t, tolerance: tolerance))
        ticking = false
        redrawViewer()
        scrubPublish?.cancel()
        if CACurrentMediaTime() - lastScrubPublish >= Self.scrubCatchUp {
            publishTime()
        } else {
            let w = DispatchWorkItem { [weak self] in self?.publishTime() }
            scrubPublish = w
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.scrubCatchUp, execute: w)
        }
    }

    static let scrubCatchUp = 0.15

    /// Tells everything that shows the time that it changed, after steps made with `ticking`.
    func publishTime() {
        lastScrubPublish = CACurrentMediaTime()
        scrubPublish?.cancel()
        scrubPublish = nil
        withMutation(keyPath: \.time) {}
        stateChanged()
    }

    func step(_ frames: Int) {
        if playing { playing = false }
        time = max(0, min(maxTime, ((time * fps).rounded() + Double(frames)) / fps))
        followPlayhead()
    }
}
