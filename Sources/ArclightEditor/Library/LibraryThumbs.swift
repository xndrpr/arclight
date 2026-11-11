import AppKit
import ArclightCore
import SwiftUI

/// Renders scene pictures off the main thread with its own `Renderer` (the editor's renderer stays on the main
/// thread for the viewport). Requests run one at a time inside the actor.
fileprivate actor ThumbWorker {
    static let shared = ThumbWorker()
    private var renderer: Renderer?

    func render(_ scene: Scene, project: Project, assets: URL?, time: Double, width: Int) -> CGImage? {
        if renderer == nil { renderer = try? Renderer(); renderer?.draft = true }
        guard let r = renderer else { return nil }
        let (cw, _) = project.size(for: scene)
        return try? r.image(
            scene: scene, project: project, assets: assets, time: time, scale: Double(width) / Double(max(cw, 1)))
    }
}

/// Memory cache (plus a small disk cache for the project list) of scene / template / project thumbnails.
@MainActor final class LibraryThumbs {
    static let shared = LibraryThumbs()
    private let cache = NSCache<NSString, CGImage>()
    private var inflight: [String: Task<CGImage?, Never>] = [:]
    init() { cache.countLimit = 400 }

    fileprivate func cached(_ key: String) -> CGImage? { cache.object(forKey: key as NSString) }

    /// Renders (deduplicated by key) and caches.
    func image(_ key: String, disk: Bool = false, make: @escaping @Sendable () async -> CGImage?) async -> CGImage? {
        if let c = cached(key) { return c }
        if disk, let img = Self.readDisk(key) { cache.setObject(img, forKey: key as NSString); return img }
        if let t = inflight[key] { return await t.value }
        let t = Task.detached(priority: .utility) { await make() }
        inflight[key] = t
        let img = await t.value
        inflight[key] = nil
        if let img {
            cache.setObject(img, forKey: key as NSString)
            if disk { Self.writeDisk(key, img) }
        }
        return img
    }

    // MARK: Kinds

    /// A scene at mid-duration, cached by project + scene id + rev.
    func scene(_ s: Scene, project: Project, projectURL: URL, width: Int = 192) async -> CGImage? {
        let key = Self.sceneKey(s, projectURL, width)
        let assets = projectURL.appendingPathComponent("assets")
        return await image(key) {
            await ThumbWorker.shared.render(s, project: project, assets: assets, time: s.duration / 2, width: width)
        }
    }

    fileprivate static func sceneKey(_ s: Scene, _ projectURL: URL, _ width: Int) -> String {
        "scene|\(projectURL.path)|\(s.id)|\(s.rev)|\(width)"
    }

    /// A template instantiated with `params` at `canvas`, in `project`'s theme (plus the tokens the template brings).
    func template(
        _ t: Template, params: [String: JSONValue], canvas: (Int, Int), project: Project?, projectURL: URL?,
        width: Int = 480
    ) async -> CGImage? {
        let key = Self.templateKey(t, params: params, canvas: canvas, projectURL: projectURL, width: width)
        var p = project ?? Project(name: "")
        p.size = [canvas.0, canvas.1]
        for (k, v) in LibraryModel.missingTokens(t, in: p) { p.theme[k] = v }
        let proj = p
        let assets = projectURL?.appendingPathComponent("assets")
        return await image(key) {
            guard var s = try? Templates.instantiate(t, params: params, sceneId: "preview", canvas: canvas) else {
                return nil
            }
            s.size = nil
            return await ThumbWorker.shared.render(s, project: proj, assets: assets, time: s.duration / 2, width: width)
        }
    }

    fileprivate static func templateKey(
        _ t: Template, params: [String: JSONValue], canvas: (Int, Int), projectURL: URL?, width: Int
    ) -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        let ps = (try? enc.encode(params)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let body = (try? enc.encode(t.scene)).map { String(Self.hash($0)) } ?? ""
        return "tpl|\(projectURL?.path ?? "")|\(t.id)|\(body)|\(canvas.0)x\(canvas.1)|\(width)|\(ps)"
    }

    /// First scene of a project on disk (for the welcome window), cached on disk by scene file date.
    func project(_ url: URL, width: Int = 160) async -> CGImage? {
        guard let first = Self.firstSceneFile(url) else { return nil }
        let stamp =
            ((try? FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate]) as? Date)?
            .timeIntervalSince1970 ?? 0
        let key = "proj|\(url.path)|\(first.lastPathComponent)|\(stamp)|\(width)"
        if let c = cached(key) { return c }
        if let img = Self.readDisk(key) { cache.setObject(img, forKey: key as NSString); return img }
        // Load on the main actor (ProjectStore registers project fonts, which isn't thread-safe), render in the worker.
        guard let store = try? ProjectStore(url: url), let s = store.orderedScenes.first else { return nil }
        let project = store.project, assets = store.assetsURL
        return await image(key, disk: true) {
            await ThumbWorker.shared.render(s, project: project, assets: assets, time: s.duration / 2, width: width)
        }
    }

    nonisolated private static func firstSceneFile(_ url: URL) -> URL? {
        struct P: Decodable { var scenes: [String]? }
        let order =
            (try? Data(contentsOf: url.appendingPathComponent("project.json"))).flatMap {
                try? JSONDecoder().decode(P.self, from: $0)
            }?.scenes ?? []
        let dir = url.appendingPathComponent("scenes")
        if let id = order.first { return dir.appendingPathComponent("\(id).json") }
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter {
            $0.pathExtension == "json"
        }
        .sorted { $0.path < $1.path }.first
    }

    // MARK: Disk cache (~/Library/Caches/Arclight/thumbs)

    nonisolated private static func hash(_ d: Data) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in d { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    nonisolated private static var diskDir: URL {
        AppPaths.thumbs
    }

    nonisolated private static func diskURL(_ key: String) -> URL {
        diskDir.appendingPathComponent(String(hash(Data(key.utf8)), radix: 16) + ".png")
    }

    nonisolated private static func readDisk(_ key: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(diskURL(key) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    nonisolated private static func writeDisk(_ key: String, _ img: CGImage) {
        try? FileManager.default.createDirectory(at: diskDir, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: diskURL(key), options: .atomic)
    }
}

/// A thumbnail frame: checker while loading, then the picture.
struct ThumbImage: View {
    let image: CGImage?
    var radius: CGFloat = 4

    var body: some View {
        ZStack {
            Checker()
            if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit) }
        }
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).stroke(UI.border, lineWidth: 1))
    }
}

/// Lazily rendered picture of a scene (scenes list).
struct SceneThumb: View {
    @ObservedObject var doc: EditorDocument
    let scene: Scene
    @State private var image: CGImage?

    var body: some View {
        let key = LibraryThumbs.sceneKey(scene, doc.url, 192)
        ThumbImage(image: LibraryThumbs.shared.cached(key) ?? image, radius: 3)
            .task(id: key) {
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                image = await LibraryThumbs.shared.scene(scene, project: doc.project, projectURL: doc.url)
            }
    }
}

/// Lazily rendered picture of a template (galleries); debounced so typing in the form doesn't queue many renders.
struct TemplateThumb: View {
    let template: Template
    var params: [String: JSONValue] = [:]
    let canvas: (Int, Int)
    var project: Project?
    var projectURL: URL?
    var width = 480
    var debounce: UInt64 = 0
    @State private var image: CGImage?

    var body: some View {
        let key = LibraryThumbs.templateKey(
            template, params: params, canvas: canvas, projectURL: projectURL, width: width)
        ThumbImage(image: LibraryThumbs.shared.cached(key) ?? image)
            .aspectRatio(CGFloat(canvas.0) / CGFloat(max(canvas.1, 1)), contentMode: .fit)
            .task(id: key) {
                if debounce > 0 { try? await Task.sleep(nanoseconds: debounce) }
                guard !Task.isCancelled else { return }
                if let img = await LibraryThumbs.shared.template(
                    template, params: params, canvas: canvas, project: project,
                    projectURL: projectURL, width: width)
                {
                    image = img
                }
            }
    }
}
