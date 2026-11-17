import AVFoundation
import ArclightCore
import Combine
import QuartzCore

/// Plays the scene's reference audio and sound clips in sync with the playhead (one player per document, created
/// lazily; one player node per clip, mixed by the engine).
///
/// - Starts when `doc.playing` turns on at rate 1 (J/L shuttle speeds and reverse are silent), stops with it.
/// - Schedules each clip's file segment for the current playhead (offset / trim / length / scene end / work-area
///   end) on its AVAudioPlayerNode, starting at a host time so a clip that begins later waits the right amount.
/// - Gain and fades follow `AudioClip.envelope` via each node's volume (updated ~60×/s).
/// - Watches for seeks and loop wraps: when the playhead drifts > 60 ms from where the audio is, it reschedules.
///   Its timer also ticks the playhead, so the clock keeps running when the viewer stops drawing frames.
final class AudioPlayback {
    private static let players = NSMapTable<EditorDocument, AudioPlayback>.weakToStrongObjects()

    /// Creates the document's player on first use (call from the transport/timeline when it appears).
    static func attach(_ doc: EditorDocument) {
        if players.object(forKey: doc) != nil { return }
        players.setObject(AudioPlayback(doc: doc), forKey: doc)
    }

    /// One clip's player node and the file it reads.
    private final class Voice {
        let player = AVAudioPlayerNode()
        var file: AVAudioFile?
        var fileKey: String?
        var ref: AudioRef?
        var connected = false
    }

    private weak var doc: EditorDocument?
    private let engine = AVAudioEngine()
    /// Master limiter, like the export's: overlapping clips never leave louder than full scale.
    private let limiter = AVAudioUnitEffect(
        audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
    /// When the scene audio speaks (for clips that duck), worked out when playback starts.
    private var speech: [ClosedRange<Double>] = []
    private var voices: [Voice] = []
    private var subs: Set<AnyCancellable> = []
    private var timer: Timer?
    /// Scene time and host time playback started from (to detect seeks).
    private var anchorT = 0.0, anchorHost = 0.0
    private var running = false

    private init(doc: EditorDocument) {
        self.doc = doc
        engine.attach(limiter)
        let out = engine.outputNode.inputFormat(forBus: 0)
        if out.sampleRate > 0, out.channelCount > 0 {
            engine.connect(engine.mainMixerNode, to: limiter, format: out)
            engine.connect(limiter, to: engine.outputNode, format: out)
        }
        // Publishers fire in willSet: re-evaluate on the next runloop turn, when the new values are in place.
        doc.$playing.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.sync(restart: false) }
        }.store(in: &subs)
        doc.$rate.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.sync(restart: true) } }
            .store(in: &subs)
        doc.$scene.map { ["\($0.audibleClips)", "\($0.duration)"] }.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.sync(restart: true) } }.store(in: &subs)
        doc.$workArea.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.sync(restart: true) }
        }.store(in: &subs)
    }

    deinit {
        timer?.invalidate()
        for v in voices { v.player.stop() }
        engine.stop()
    }

    private var shouldPlay: Bool {
        guard let doc, doc.playing, doc.rate == 1, !doc.scene.audibleClips.isEmpty else { return false }
        return true
    }

    private func sync(restart: Bool) {
        if shouldPlay {
            if !running || restart { start() }
        } else if running {
            stop()
        }
    }

    /// Opens `ref`'s file on `v` (reusing it when unchanged) and connects the node with the file's format.
    private func load(_ v: Voice, _ ref: AudioRef) -> AVAudioFile? {
        guard let doc else { return nil }
        let url = SceneAudio.url(ref, assets: doc.assets)
        let stamp =
            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(stamp)"
        v.ref = ref
        if key == v.fileKey, let f = v.file { return f }
        v.player.stop()
        v.file = try? AVAudioFile(forReading: url)
        v.fileKey = key
        if let f = v.file {
            if v.connected { engine.disconnectNodeOutput(v.player) }
            engine.connect(v.player, to: engine.mainMixerNode, format: f.processingFormat)
            v.connected = true
        }
        return v.file
    }

    private func clip(_ v: Voice) -> AudioClip? {
        guard let doc, let f = v.file, let ref = v.ref else { return nil }
        let isReference = ref == doc.scene.audio
        return AudioClip(
            ref, fileDuration: Double(f.length) / f.processingFormat.sampleRate, sceneDuration: doc.scene.duration,
            speech: isReference ? [] : speech)
    }

    private func start() {
        guard let doc else { stop(); return }
        let clips = doc.scene.audibleClips
        guard !clips.isEmpty else { stop(); return }
        for v in voices { v.player.stop() }
        while voices.count < clips.count {
            let v = Voice()
            engine.attach(v.player)
            voices.append(v)
        }
        while voices.count > clips.count {
            let v = voices.removeLast()
            v.player.stop()
            engine.detach(v.player)
        }
        for (v, ref) in zip(voices, clips) { _ = load(v, ref) }
        speech = SceneAudio.speech(doc.scene, assets: doc.assets)
        guard voices.contains(where: { $0.file != nil }) else { stop(); return }
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { running = false; return }
        }
        let t = doc.playTime
        let until = doc.workArea.map { min($0.upperBound, doc.scene.duration) } ?? doc.scene.duration
        anchorT = t; anchorHost = CACurrentMediaTime()
        running = true
        startTimer()
        let now = mach_absolute_time()
        for v in voices {
            guard let f = v.file, let c = clip(v), let seg = c.segment(from: t, until: until),
                let fr = AudioClip.frames(seg, sampleRate: f.processingFormat.sampleRate, fileFrames: f.length)
            else { continue }
            v.player.volume = Float(c.envelope(at: t + seg.delay))
            v.player.pan = Float(c.pan)
            v.player.scheduleSegment(f, startingFrame: fr.start, frameCount: AVAudioFrameCount(fr.count), at: nil)
            let when = now + AVAudioTime.hostTime(forSeconds: seg.delay)
            v.player.play(at: seg.delay > 0.001 ? AVAudioTime(hostTime: when) : nil)
        }
    }

    private func stop() {
        for v in voices { v.player.stop() }
        running = false
        timer?.invalidate(); timer = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Volume envelopes + seek / loop detection.
    private func update() {
        guard running, let doc else { return }
        // Advance the playhead here too: the viewer only ticks when it draws, and when its frames stall (no
        // drawable, window idle until the mouse moves) a frozen playTime would read as a seek every 60 ms and
        // restart the audio on the same few milliseconds over and over.
        if doc.playing { _ = doc.tick() }
        guard doc.playing else { return }
        let expected = anchorT + (CACurrentMediaTime() - anchorHost)
        if abs(doc.playTime - expected) > 0.06 { start(); return }
        for v in voices {
            if let c = clip(v) { v.player.volume = Float(c.envelope(at: doc.playTime)) }
        }
    }
}
