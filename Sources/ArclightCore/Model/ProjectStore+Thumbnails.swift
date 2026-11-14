import Foundation

/// Thumbnail pages (`thumbnails/<id>.json`): saved like scenes, with `rev` conflict checks and history snapshots in
/// `.history/~<id>/` (`~` never starts a scene id, so the folders can't collide).
extension ProjectStore {
    static func thumbnailHistoryKey(_ id: String) -> String { "~" + id }

    public func thumbnail(_ id: String?) throws -> Thumbnail {
        if let id {
            guard let p = thumbnails[id] else { throw ModelError.notFound("thumbnail '\(id)'") }
            return p
        }
        guard let first = orderedThumbnails.first else { throw ModelError.notFound("project has no thumbnails") }
        return first
    }

    /// Saves a thumbnail page, bumping `rev`, and records a history snapshot. `expectedRev` rejects stale writes.
    @discardableResult
    public func save(
        thumbnail: Thumbnail, expectedRev: Int? = nil, summary: String = "edit", source: ChangeSource = .cli
    ) throws -> Thumbnail {
        try SafeName.component(thumbnail.id, what: "thumbnail id")
        let current = thumbnails[thumbnail.id]
        if let expectedRev, let cur = current, cur.rev != expectedRev {
            throw ModelError.invalid(
                "thumbnail '\(thumbnail.id)' changed (rev \(cur.rev), expected \(expectedRev)); re-read it")
        }
        var ids = Set<String>()
        for a in thumbnail.artboards {
            try SafeName.component(a.id, what: "artboard id")
            guard ids.insert(a.id).inserted else { throw ModelError.invalid("duplicate artboard id '\(a.id)'") }
        }
        let key = ProjectStore.thumbnailHistoryKey(thumbnail.id)
        if let cur = current, !FileManager.default.fileExists(atPath: historyFile(key, cur.rev).path) {
            recordHistory(cur, key: key, rev: cur.rev, summary: "before", source: source.rawValue, changed: nil)
        }
        var p = thumbnail
        p.rev = (current?.rev ?? thumbnail.rev) + 1
        try FileManager.default.createDirectory(at: thumbnailsURL, withIntermediateDirectories: true)
        try ProjectStore.write(p, to: thumbnailsURL.appendingPathComponent("\(p.id).json"))
        thumbnails[p.id] = p
        recordHistory(
            p, key: key, rev: p.rev, summary: summary, source: source.rawValue,
            changed: ThumbnailDiff.changed(current, p))
        if !project.thumbnails.contains(p.id) { project.thumbnails.append(p.id); try saveProject() }
        return p
    }

    public func deleteThumbnail(_ id: String) throws {
        try SafeName.component(id, what: "thumbnail id")
        try? FileManager.default.removeItem(at: thumbnailsURL.appendingPathComponent("\(id).json"))
        thumbnails[id] = nil
        project.thumbnails.removeAll { $0 == id }
        try saveProject()
    }

    public func thumbnailHistory(_ id: String) -> [HistoryEntry] { history(key: ProjectStore.thumbnailHistoryKey(id)) }

    public func thumbnailSnapshot(_ id: String, rev: Int) -> Thumbnail? {
        guard SafeName.isComponent(id) else { return nil }
        return JSONFile.read(Thumbnail.self, from: historyFile(ProjectStore.thumbnailHistoryKey(id), rev))
    }

    /// Restores a thumbnail snapshot as a new revision.
    @discardableResult
    public func revertThumbnail(_ id: String, to rev: Int, source: ChangeSource = .cli) throws -> Thumbnail {
        guard let old = thumbnailSnapshot(id, rev: rev) else { throw ModelError.notFound("rev \(rev) of thumbnail '\(id)'") }
        return try save(thumbnail: old, summary: "revert to \(rev)", source: source)
    }

    /// Saves one artboard edited as a scene (`Artboard.asScene`) back into its thumbnail.
    @discardableResult
    public func save(
        artboardScene s: Scene, thumbnail id: String, artboard: String, expectedRev: Int? = nil,
        summary: String = "edit", source: ChangeSource = .cli
    ) throws -> Thumbnail {
        var p = try thumbnail(id)
        let i = try p.index(of: artboard)
        p.artboards[i].update(from: s)
        return try save(thumbnail: p, expectedRev: expectedRev, summary: summary, source: source)
    }
}

/// What changed between two revisions of a thumbnail: artboard ids, and `artboard/node` ids inside them.
public enum ThumbnailDiff {
    public static func changed(_ a: Thumbnail?, _ b: Thumbnail) -> [String] {
        guard let a else { return b.artboards.map(\.id) }
        var out: [String] = []
        let old = Dictionary(a.artboards.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        for ab in b.artboards {
            guard let o = old[ab.id] else { out.append(ab.id); continue }
            guard o != ab else { continue }
            let d = SceneDiff.diff(o.asScene(thumbnail: a.id), ab.asScene(thumbnail: b.id))
            out += d.all.isEmpty ? [ab.id] : d.all.map { "\(ab.id)/\($0)" }
        }
        let now = Set(b.artboards.map(\.id))
        out += a.artboards.map(\.id).filter { !now.contains($0) }
        return out
    }
}
