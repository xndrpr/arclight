import AppKit
import ArclightCore
import SwiftUI

/// Lazily rendered layer thumbnails, cached by project + scene rev + layer id + coarse time bucket.
@MainActor final class LayerThumbs {
    static let shared = LayerThumbs()
    private static let bucket = 0.5  // seconds
    static let size = CGSize(width: 48, height: 27)

    private let cache = NSCache<NSString, CGImage>()
    private init() { cache.countLimit = 600 }

    fileprivate static func key(_ doc: EditorDocument, _ id: String, time: Double) -> String {
        "\(doc.url.path)|\(doc.scene.id)|\(doc.scene.rev)|\(id)|\(bucketTime(doc, id, time))"
    }

    /// Time bucket clamped into the layer's in/out so the thumbnail shows something.
    private static func bucketTime(_ doc: EditorDocument, _ id: String, _ time: Double) -> Double {
        let b = (time / bucket).rounded(.down) * bucket
        guard let n = doc.scene.node(id) else { return b }
        let st = n.start ?? 0, en = max(n.end ?? doc.scene.duration, st)
        // Outside the layer's in/out: show it mid-way (past most intro reveals) rather than at its first frame.
        if b < st || b >= en { return (st + en) / 2 }
        return b
    }

    fileprivate func cached(_ key: String) -> CGImage? { cache.object(forKey: key as NSString) }

    /// Renders after a short debounce (scrubbing cancels stale requests) on the main actor, one at a time.
    func render(_ doc: EditorDocument, id: String, time: Double, key: String) async -> CGImage? {
        if let c = cached(key) { return c }
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled else { return nil }
        // Re-check after the sleep: another row may have rendered the same key meanwhile.
        if let c = cached(key) { return c }
        let t = Self.bucketTime(doc, id, time)
        guard
            let img = try? doc.renderer.thumbnail(
                scene: doc.scene, project: doc.project, assets: doc.assets, layer: id,
                time: t, width: Int(Self.size.width * 2))
        else { return nil }
        cache.setObject(img, forKey: key as NSString)
        return img
    }
}

struct LayerThumbnail: View {
    @ObservedObject var doc: EditorDocument
    let id: String
    let time: Double
    @State private var image: CGImage?

    var body: some View {
        let key = LayerThumbs.key(doc, id, time: time)
        ZStack {
            Checker()
            if let image = LayerThumbs.shared.cached(key) ?? image {
                // Thumbnails render on black; screen-blending lets the checker show through the empty parts.
                Image(decorative: image, scale: 2).resizable().aspectRatio(contentMode: .fit).blendMode(.screen)
            }
        }
        .compositingGroup()
        .frame(width: LayerThumbs.size.width, height: LayerThumbs.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(UI.border, lineWidth: 1))
        .task(id: key) {
            if let img = await LayerThumbs.shared.render(doc, id: id, time: time, key: key) { image = img }
        }
    }
}
