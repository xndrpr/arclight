import ArclightCore
import Foundation

/// The two things a project can hold. A project may have only one of them.
enum Workspace: String, CaseIterable, Identifiable {
    case motion, preview
    var id: String { rawValue }
    var title: String { self == .motion ? "Motion" : "Preview" }
    var symbol: String { self == .motion ? "film" : "photo.on.rectangle" }
}

/// What the document's working `scene` is a copy of.
enum EditTarget: Equatable {
    case scene(String)
    case artboard(preview: String, artboard: String)
    /// Nothing to edit yet (an empty workspace); `scene` is a placeholder that is never saved.
    case none

    var previewId: String? { if case .artboard(let p, _) = self { return p }; return nil }
    var artboardId: String? { if case .artboard(_, let a) = self { return a }; return nil }
}

extension EditorDocument {
    static let placeholderSceneId = "~none"

    /// A new page with one YouTube-sized artboard on the theme background.
    static func starterPreview(id: String, name: String? = nil) -> Preview {
        var a = Artboard(id: "a", name: "A")
        a.background = .value("$bg")
        return Preview(id: id, name: name ?? "Thumbnail", artboards: [a])
    }

    static func placeholderScene() -> Scene { Scene(id: placeholderSceneId, duration: 5) }

    /// The first thing to open in a workspace: its first scene, or the first artboard of its first preview.
    static func initialTarget(_ ws: Workspace, store st: ProjectStore) -> (Scene, EditTarget, Int) {
        switch ws {
        case .motion:
            if let s = st.orderedScenes.first { return (s, .scene(s.id), s.rev) }
        case .preview:
            if let p = st.orderedPreviews.first, let a = p.artboards.first {
                return (a.asScene(preview: p.id, rev: p.rev), .artboard(preview: p.id, artboard: a.id), p.rev)
            }
        }
        return (placeholderScene(), .none, 0)
    }

    var isPreview: Bool { workspace == .preview }
    var isEmptyWorkspace: Bool { target == .none }

    /// The open preview page as stored (the working artboard is `scene`).
    var openPreview: Preview? { target.previewId.flatMap { store.previews[$0] } }

    var previews: [Preview] { store.orderedPreviews }

    /// The stored project, with the open preview's detached theme over it.
    func effectiveProject() -> Project {
        if let p = openPreview { return store.project.rendering(p) }
        return store.project
    }

    /// Whether the open preview has its own theme (theme edits then go to it, not to the project).
    var themeIsDetached: Bool { openPreview?.theme.isDetached ?? false }

    // MARK: Workspace

    func setWorkspace(_ ws: Workspace) {
        guard ws != workspace else { return }
        saveNow()
        workspace = ws
        var p = store.project
        p.workspace = ws.rawValue
        try? store.update(project: p)
        let (s, t, rev) = EditorDocument.initialTarget(ws, store: store)
        open(s, target: t, rev: rev)
    }

    /// Makes `s` the working copy for `t`, with fresh per-target state (see `switchTo`).
    func open(_ s: Scene, target t: EditTarget, rev: Int) {
        target = t
        switchTo(s)
        baseRev = rev
        project = effectiveProject()
        stateChanged()
    }

    // MARK: Pages & artboards

    func open(preview id: String, artboard: String? = nil) {
        saveNow()
        guard let p = store.previews[id], let a = p.artboard(artboard) ?? p.artboards.first else { return }
        open(a.asScene(preview: p.id, rev: p.rev), target: .artboard(preview: p.id, artboard: a.id), rev: p.rev)
    }

    /// Opens a scene id from the activity feed or history, which may name an artboard (`<preview>~<artboard>`).
    func open(sceneOrArtboard id: String) -> Bool {
        if let r = id.range(of: "~") {
            let p = String(id[..<r.lowerBound]), a = String(id[r.upperBound...])
            guard store.previews[p]?.artboard(a) != nil else { return false }
            if workspace != .preview { workspace = .preview }
            open(preview: p, artboard: a)
            return true
        }
        guard store.scenes[id] != nil else { return false }
        if workspace != .motion { workspace = .motion }
        open(scene: id)
        return true
    }

    func newPreview() {
        saveNow()
        var k = store.previews.count + 1
        while store.previews["preview-\(k)"] != nil { k += 1 }
        let p = EditorDocument.starterPreview(id: "preview-\(k)", name: "Thumbnail \(k)")
        if let saved = try? store.save(preview: p, summary: "create", source: .editor) {
            refreshProject()
            if workspace != .preview { workspace = .preview }
            open(preview: saved.id)
        }
    }

    /// Runs page ops (`PreviewOps`) on a stored preview, saving the working artboard first, then reopens
    /// `reopen` (default: the artboard that was open, or the page's first if it was removed).
    @discardableResult
    func applyPage(_ id: String, _ ops: [JSONValue], summary: String? = nil, reopen: String? = nil) -> Bool {
        saveNow()
        guard let p = store.previews[id] else { return false }
        do {
            let r = try PreviewOps.apply(ops, to: p)
            let saved = try store.save(preview: r.preview, summary: summary ?? r.summary, source: .editor)
            ActivityLog.append(
                ActivityEntry(
                    source: .editor, tool: "edit", scene: nil, summary: "\(saved.id): \(summary ?? r.summary)",
                    changed: r.changed, revBefore: p.rev, revAfter: saved.rev, write: true), project: url)
            refreshProject()
            if target.previewId == id || reopen != nil {
                let want = reopen ?? target.artboardId
                open(preview: id, artboard: saved.artboard(want) != nil ? want : nil)
            }
            return true
        } catch {
            flash("\(error)")
            return false
        }
    }

    func addArtboard(preset: ArtboardPresets.Preset, to id: String? = nil) {
        guard let pid = id ?? target.previewId, let p = store.previews[pid] else { return }
        let aid = p.uniqueArtboardId(preset.id)
        applyPage(
            pid,
            [["op": "artboard_add", "id": .string(aid), "name": .string(preset.title.components(separatedBy: " · ")[0]),
              "size": .array(preset.size.map { .number(Double($0)) })]],
            summary: "add artboard \(aid)", reopen: aid)
    }

    /// A variant: same layers, placed to the right, named B, C, D…
    func duplicateArtboard(_ aid: String, in pid: String) {
        guard let p = store.previews[pid], let a = p.artboard(aid) else { return }
        let letters = (66...90).compactMap { UnicodeScalar($0).map { String(Character($0)) } }
        let used = Set(p.artboards.compactMap(\.name))
        let name = letters.first { !used.contains($0) } ?? ((a.name ?? aid) + " copy")
        let newId = p.uniqueArtboardId(name.lowercased().replacingOccurrences(of: " ", with: "-"))
        applyPage(
            pid, [["op": "artboard_duplicate", "id": .string(aid), "as": .string(newId), "name": .string(name)]],
            summary: "variant \(newId) of \(aid)", reopen: newId)
    }

    func deleteArtboard(_ aid: String, in pid: String) {
        guard let p = store.previews[pid] else { return }
        guard p.artboards.count > 1 else { flash("A preview needs at least one artboard — delete the preview instead"); return }
        applyPage(pid, [["op": "artboard_remove", "id": .string(aid)]], summary: "remove artboard \(aid)")
    }

    func renameArtboard(_ aid: String, in pid: String, _ name: String) {
        if target == .artboard(preview: pid, artboard: aid) {
            edit { $0.name = name.isEmpty ? nil : name }; saveNow(); return
        }
        applyPage(pid, [["op": "artboard_set", "id": .string(aid), "name": name.isEmpty ? .null : .string(name)]])
    }

    func renamePreview(_ pid: String, _ name: String) {
        applyPage(pid, [["op": "preview", "name": name.isEmpty ? .null : .string(name)]], summary: "rename")
    }

    func duplicatePreview(_ pid: String) {
        saveNow()
        guard var p = store.previews[pid] else { return }
        var k = 2
        while store.previews["\(pid)-\(k)"] != nil { k += 1 }
        p.id = "\(pid)-\(k)"; p.rev = 0; p.name = (p.name ?? pid) + " copy"
        if let saved = try? store.save(preview: p, summary: "duplicate", source: .editor) {
            refreshProject(); open(preview: saved.id)
        }
    }

    func deletePreview(_ pid: String) {
        try? store.deletePreview(pid)
        refreshProject()
        if target.previewId == pid {
            let (s, t, rev) = EditorDocument.initialTarget(.preview, store: store)
            open(s, target: t, rev: rev)
        }
    }

    // MARK: Theme link

    /// Gives the open preview its own copy of the theme; project theme changes no longer reach it.
    func detachTheme() {
        guard let p = openPreview, !p.theme.isDetached else { return }
        applyPage(
            p.id, [["op": "preview", "theme": ["detached": true, "tokens": .object(store.project.theme)]]],
            summary: "detach theme")
        flash("This preview now has its own theme")
    }

    /// Links the open preview back to the project theme (its own tokens are dropped; undo via History).
    func relinkTheme() {
        guard let p = openPreview, p.theme.isDetached else { return }
        applyPage(p.id, [["op": "preview", "theme": "project"]], summary: "link theme to project")
        flash("Theme linked to the project again")
    }

    /// Theme edits while a detached preview is open: saved as that preview's tokens.
    func writeDetachedTheme(_ theme: [String: JSONValue]) -> Bool {
        guard let p = openPreview, p.theme.isDetached else { return false }
        applyPage(p.id, [["op": "preview", "theme": ["detached": true, "tokens": .object(theme)]]], summary: "theme")
        return true
    }
}
