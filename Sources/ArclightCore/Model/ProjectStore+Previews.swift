import Foundation

/// Preview pages (`previews/<id>.json`): saved like scenes, with `rev` conflict checks and history snapshots in
/// `.history/~<id>/` (`~` never starts a scene id, so the folders can't collide).
extension ProjectStore {
    static func previewHistoryKey(_ id: String) -> String { "~" + id }

    public func preview(_ id: String?) throws -> Preview {
        if let id {
            guard let p = previews[id] else { throw ModelError.notFound("preview '\(id)'") }
            return p
        }
        guard let first = orderedPreviews.first else { throw ModelError.notFound("project has no previews") }
        return first
    }

    /// Saves a preview page, bumping `rev`, and records a history snapshot. `expectedRev` rejects stale writes.
    @discardableResult
    public func save(
        preview: Preview, expectedRev: Int? = nil, summary: String = "edit", source: ChangeSource = .cli
    ) throws -> Preview {
        try SafeName.component(preview.id, what: "preview id")
        let current = previews[preview.id]
        if let expectedRev, let cur = current, cur.rev != expectedRev {
            throw ModelError.invalid(
                "preview '\(preview.id)' changed (rev \(cur.rev), expected \(expectedRev)); re-read it")
        }
        var ids = Set<String>()
        for a in preview.artboards {
            try SafeName.component(a.id, what: "artboard id")
            guard ids.insert(a.id).inserted else { throw ModelError.invalid("duplicate artboard id '\(a.id)'") }
        }
        let key = ProjectStore.previewHistoryKey(preview.id)
        if let cur = current, !FileManager.default.fileExists(atPath: historyFile(key, cur.rev).path) {
            recordHistory(cur, key: key, rev: cur.rev, summary: "before", source: source.rawValue, changed: nil)
        }
        var p = preview
        p.rev = (current?.rev ?? preview.rev) + 1
        try FileManager.default.createDirectory(at: previewsURL, withIntermediateDirectories: true)
        try ProjectStore.write(p, to: previewsURL.appendingPathComponent("\(p.id).json"))
        previews[p.id] = p
        recordHistory(
            p, key: key, rev: p.rev, summary: summary, source: source.rawValue,
            changed: PreviewDiff.changed(current, p))
        if !project.previews.contains(p.id) { project.previews.append(p.id); try saveProject() }
        return p
    }

    public func deletePreview(_ id: String) throws {
        try SafeName.component(id, what: "preview id")
        try? FileManager.default.removeItem(at: previewsURL.appendingPathComponent("\(id).json"))
        previews[id] = nil
        project.previews.removeAll { $0 == id }
        try saveProject()
    }

    public func previewHistory(_ id: String) -> [HistoryEntry] { history(key: ProjectStore.previewHistoryKey(id)) }

    public func previewSnapshot(_ id: String, rev: Int) -> Preview? {
        guard SafeName.isComponent(id) else { return nil }
        return JSONFile.read(Preview.self, from: historyFile(ProjectStore.previewHistoryKey(id), rev))
    }

    /// Restores a preview snapshot as a new revision.
    @discardableResult
    public func revertPreview(_ id: String, to rev: Int, source: ChangeSource = .cli) throws -> Preview {
        guard let old = previewSnapshot(id, rev: rev) else { throw ModelError.notFound("rev \(rev) of preview '\(id)'") }
        return try save(preview: old, summary: "revert to \(rev)", source: source)
    }

    /// Saves one artboard edited as a scene (`Artboard.asScene`) back into its preview.
    @discardableResult
    public func save(
        artboardScene s: Scene, preview id: String, artboard: String, expectedRev: Int? = nil,
        summary: String = "edit", source: ChangeSource = .cli
    ) throws -> Preview {
        var p = try preview(id)
        let i = try p.index(of: artboard)
        p.artboards[i].update(from: s)
        return try save(preview: p, expectedRev: expectedRev, summary: summary, source: source)
    }
}

/// What changed between two revisions of a preview: artboard ids, and `artboard/node` ids inside them.
public enum PreviewDiff {
    public static func changed(_ a: Preview?, _ b: Preview) -> [String] {
        guard let a else { return b.artboards.map(\.id) }
        var out: [String] = []
        let old = Dictionary(a.artboards.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        for ab in b.artboards {
            guard let o = old[ab.id] else { out.append(ab.id); continue }
            guard o != ab else { continue }
            let d = SceneDiff.diff(o.asScene(preview: a.id), ab.asScene(preview: b.id))
            out += d.all.isEmpty ? [ab.id] : d.all.map { "\(ab.id)/\($0)" }
        }
        let now = Set(b.artboards.map(\.id))
        out += a.artboards.map(\.id).filter { !now.contains($0) }
        return out
    }
}
