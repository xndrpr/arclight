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
        if now - lastPublish > 1.0 / 20 {
            lastPublish = now
            time = (playTime * fps).rounded(.down) / fps
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

    /// Stops playback and puts the playhead at `t` (snapped, then clamped): a click or drag in the ruler or tracks.
    func scrub(to t: Double, tolerance: Double) {
        playing = false
        time = clampedTime(snapTime(t, tolerance: tolerance))
    }

    func step(_ frames: Int) {
        playing = false
        time = max(0, min(maxTime, ((time * fps).rounded() + Double(frames)) / fps))
        followPlayhead()
    }
}
