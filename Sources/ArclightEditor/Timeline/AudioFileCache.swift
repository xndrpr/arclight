import AppKit
import ArclightCore
import SwiftUI

/// File info and waveform peaks for the audio lane, loaded off the main thread and cached per file + mtime.
final class AudioFileCache {
    static let shared = AudioFileCache()
    /// Waveform resolution: peaks per second of audio (capped).
    private static let peaksPerSecond = 200.0

    struct Entry { var info: SceneAudio.Info; var peaks: [Float]? }
    private var entries: [String: Entry] = [:]
    private var loading: Set<String> = []

    private func key(_ url: URL) -> String {
        let stamp =
            ((try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)?
            .timeIntervalSince1970 ?? 0
        return "\(url.path)|\(stamp)"
    }

    /// Peaks scaled so the loudest is 1 (quiet voiceovers stay readable); near-silent files aren't boosted.
    private static func normalized(_ p: [Float]) -> [Float] {
        let m = max(p.max() ?? 0, 0.05)
        return p.map { $0 / m }
    }

    /// Info right away (cheap); peaks once loaded — `onLoad` fires on the main thread when they arrive.
    func entry(_ url: URL, onLoad: @escaping () -> Void) -> Entry? {
        let k = key(url)
        if let e = entries[k], e.peaks != nil { return e }
        if entries[k] == nil {
            guard let info = SceneAudio.info(url) else { return nil }
            entries[k] = Entry(info: info, peaks: nil)
        }
        if !loading.contains(k), let info = entries[k]?.info {
            let buckets = max(1, min(200_000, Int(info.duration * Self.peaksPerSecond)))
            if info.duration <= 20 {  // short clips: cheap enough to read right away (no empty first frame)
                entries[k]?.peaks = Self.normalized(SceneAudio.peaks(url, buckets: buckets))
                return entries[k]
            }
            loading.insert(k)
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Self.normalized(SceneAudio.peaks(url, buckets: buckets))
                DispatchQueue.main.async {
                    self.entries[k]?.peaks = p
                    self.loading.remove(k)
                    onLoad()
                }
            }
        }
        return entries[k]
    }
}

extension EditorDocument {
    /// The scene's audio placement, or nil when there's no audio (or the file can't be read).
    func audioClip(onLoad: @escaping () -> Void = {}) -> (clip: AudioClip, ref: AudioRef, entry: AudioFileCache.Entry)?
    {
        guard let a = scene.audio,
            let e = AudioFileCache.shared.entry(SceneAudio.url(a, assets: assets), onLoad: onLoad)
        else { return nil }
        return (AudioClip(a, fileDuration: e.info.duration, sceneDuration: scene.duration), a, e)
    }
}
