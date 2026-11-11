import AVFoundation
import ArclightCore
import Combine
import QuartzCore

/// Plays the scene's reference audio in sync with the playhead (one player per document, created lazily).
///
/// - Starts when `doc.playing` turns on at rate 1 (J/L shuttle speeds and reverse are silent), stops with it.
/// - Schedules the file segment for the current playhead (offset / trim / scene end / work-area end) on an
///   AVAudioPlayerNode, starting at a host time so a clip that begins later waits the right amount.
/// - Gain and fades follow `AudioClip.envelope` via the node's volume (updated ~60×/s).
/// - Watches for seeks and loop wraps: when the playhead drifts > 60 ms from where the audio is, it reschedules.
final class AudioPlayback {
    private static let players = NSMapTable<EditorDocument, AudioPlayback>.weakToStrongObjects()

    /// Creates the document's player on first use (call from the transport/timeline when it appears).
    static func attach(_ doc: EditorDocument) {
        if players.object(forKey: doc) != nil { return }
        players.setObject(AudioPlayback(doc: doc), forKey: doc)
    }

    private weak var doc: EditorDocument?
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var fileKey: String?
    private var connected = false
    private var subs: Set<AnyCancellable> = []
    private var timer: Timer?
    /// Scene time and host time playback started from (to detect seeks).
    private var anchorT = 0.0, anchorHost = 0.0
    private var running = false

    private init(doc: EditorDocument) {
        self.doc = doc
        engine.attach(player)
        // Publishers fire in willSet: re-evaluate on the next runloop turn, when the new values are in place.
        doc.$playing.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.sync(restart: false) }
        }.store(in: &subs)
        doc.$rate.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.sync(restart: true) } }
            .store(in: &subs)
        doc.$scene.map { [$0.audio.map { "\($0)" } ?? "", "\($0.duration)"] }.removeDuplicates()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.sync(restart: true) } }.store(in: &subs)
        doc.$workArea.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.sync(restart: true) }
        }.store(in: &subs)
    }

    deinit { timer?.invalidate(); player.stop(); engine.stop() }

    private var shouldPlay: Bool {
        guard let doc, doc.playing, doc.rate == 1, let a = doc.scene.audio, a.mute != true else { return false }
        return true
    }

    private func sync(restart: Bool) {
        if shouldPlay {
            if !running || restart { start() }
        } else if running {
            stop()
        }
    }

    private func loadFile() -> AVAudioFile? {
        guard let doc, let a = doc.scene.audio else { return nil }
        let url = SceneAudio.url(a, assets: doc.assets)
        let stamp =
            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "\(url.path)|\(stamp)"
        if key == fileKey, let file { return file }
        player.stop()
        file = try? AVAudioFile(forReading: url)
        fileKey = key
        if let f = file {
            if connected { engine.disconnectNodeOutput(player) }
            engine.connect(player, to: engine.mainMixerNode, format: f.processingFormat)
            connected = true
        }
        return file
    }

    private func start() {
        guard let doc, let f = loadFile(), let a = doc.scene.audio else { stop(); return }
        player.stop()
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch { running = false; return }
        }
        let t = doc.playTime
        let clip = AudioClip(
            a, fileDuration: Double(f.length) / f.processingFormat.sampleRate, sceneDuration: doc.scene.duration)
        let until = doc.workArea.map { min($0.upperBound, doc.scene.duration) } ?? doc.scene.duration
        anchorT = t; anchorHost = CACurrentMediaTime()
        running = true
        startTimer()
        guard let seg = clip.segment(from: t, until: until),
            let fr = AudioClip.frames(seg, sampleRate: f.processingFormat.sampleRate, fileFrames: f.length)
        else { return }
        player.volume = Float(clip.envelope(at: t + seg.delay))
        player.scheduleSegment(f, startingFrame: fr.start, frameCount: AVAudioFrameCount(fr.count), at: nil)
        let when = mach_absolute_time() + AVAudioTime.hostTime(forSeconds: seg.delay)
        player.play(at: seg.delay > 0.001 ? AVAudioTime(hostTime: when) : nil)
    }

    private func stop() {
        player.stop()
        running = false
        timer?.invalidate(); timer = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.update() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Volume envelope + seek / loop detection.
    private func update() {
        guard running, let doc, let a = doc.scene.audio, let f = file else { return }
        let expected = anchorT + (CACurrentMediaTime() - anchorHost)
        if abs(doc.playTime - expected) > 0.06 { start(); return }
        let clip = AudioClip(
            a, fileDuration: Double(f.length) / f.processingFormat.sampleRate, sceneDuration: doc.scene.duration)
        player.volume = Float(clip.envelope(at: doc.playTime))
    }
}
