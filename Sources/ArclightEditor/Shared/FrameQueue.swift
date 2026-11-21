import SwiftUI

/// Renders small frames on the main thread (the editor's renderer) one at a time, `delay` apart so scrolling and
/// typing stay smooth, and keeps them by key (all dropped past `cap`).
class FrameQueue: ObservableObject {
    @Published private(set) var images: [String: CGImage] = [:]
    private var queue: [(key: String, job: () -> CGImage?)] = []
    private var running = false
    private let delay: Double
    private let cap: Int

    init(delay: Double, cap: Int) { self.delay = delay; self.cap = cap }

    /// Queues `job` for `key` unless its image is kept or already queued.
    func enqueue(_ key: String, _ job: @escaping () -> CGImage?) {
        guard images[key] == nil, !queue.contains(where: { $0.key == key }) else { return }
        queue.append((key, job))
        pump()
    }

    func cancel(_ key: String) { queue.removeAll { $0.key == key } }

    private func pump() {
        guard !running, !queue.isEmpty else { return }
        running = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.running = false
            // Views may cancel their jobs while we wait (scrolling, switching tabs), so the queue can be empty here.
            guard !self.queue.isEmpty else { return }
            let next = self.queue.removeFirst()
            if let img = next.job() {
                if self.images.count > self.cap { self.images.removeAll() }
                self.images[next.key] = img
            }
            self.pump()
        }
    }
}
