import ArclightCore
import SwiftUI

/// Renders the frames choice tiles show, one at a time on the main thread (the editor's renderer), cached by
/// scene revision. Draft scenes are read straight from disk so a tile never waits for the editor's next poll.
final class ChoiceFrames: ObservableObject {
    @Published private(set) var images: [String: CGImage] = [:]
    private var scenes: [String: (scene: Scene?, read: Date)] = [:]
    private var queue: [(key: String, job: () -> CGImage?)] = []
    private var running = false

    static let loopFPS: Double = 12

    /// Times of a looping tile's frames: the whole scene at `loopFPS`, at most 36 frames.
    static func loopTimes(_ s: Scene) -> [Double] {
        let d = max(0.1, s.duration)
        let n = max(2, min(36, Int((d * loopFPS).rounded())))
        return (0..<n).map { Double($0) * d / Double(n) }
    }

    func scene(_ doc: EditorDocument, _ id: String) -> Scene? {
        // Re-read at most once a second (an agent may change a draft before the user answers).
        if let c = scenes[id], Date().timeIntervalSince(c.read) < 1 { return c.scene }
        let url = doc.url.appendingPathComponent("scenes").appendingPathComponent("\(id).json")
        let s = JSONFile.read(Scene.self, from: url) ?? doc.store.scenes[id]
        // Keep the last copy after the drafts are deleted, so answered cards keep their pictures this session.
        let kept = s ?? scenes[id]?.scene
        scenes[id] = (kept, Date())  // not published: setting it inside a view update is fine
        return kept
    }

    func image(_ doc: EditorDocument, _ s: Scene, _ t: Double, _ width: Double) -> CGImage? {
        let k = "\(s.id):\(s.rev):\(Int((t * 1000).rounded())):\(Int(width))"
        if let img = images[k] { return img }
        if !queue.contains(where: { $0.key == k }) {
            queue.append((k, { [weak doc] in doc?.preview(s, time: t, width: width) }))
            DispatchQueue.main.async { self.pump() }
        }
        return nil
    }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
            guard let self else { return }
            self.running = false
            guard !self.queue.isEmpty else { return }
            let next = self.queue.removeFirst()
            if let img = next.job() {
                if self.images.count > 600 { self.images.removeAll() }
                self.images[next.key] = img
            }
            self.pump()
        }
    }
}
