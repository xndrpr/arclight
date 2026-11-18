import ArclightCore
import Foundation

extension EditorDocument {
    // MARK: Saving & live reload

    func scheduleSave() {
        savePending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.saveNow() }
        savePending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    func saveNow() {
        savePending?.cancel(); savePending = nil
        switch target {
        case .none: return
        case .artboard(let pid, let aid): saveArtboard(pid, aid); return
        case .scene: break
        }
        guard scene != store.scenes[scene.id] || scene.rev != baseRev else { return }
        if let disk = store.scenes[scene.id], disk == scene { return }
        do {
            let prev = store.scenes[scene.id]
            let diff = SceneDiff.diff(prev, scene)
            let saved = try store.save(scene: scene, expectedRev: baseRev, summary: diff.summary, source: .editor)
            ActivityLog.append(
                ActivityEntry(
                    source: .editor, tool: "edit", scene: scene.id, summary: diff.summary,
                    changed: diff.all.isEmpty ? nil : diff.all, revBefore: prev?.rev, revAfter: saved.rev,
                    write: true), project: url)
            baseRev = saved.rev
            var s = scene; s.rev = saved.rev
            if s != scene { scene = s }
            stamps = fileStamps()
        } catch {
            // Someone else (the AI) saved first: theirs wins, ours stays in undo.
            try? store.reload()
            if let disk = store.scenes[scene.id] {
                undoStack.append(scene)
                scene = disk; baseRev = disk.rev
                flash("Scene changed outside the editor — reloaded (⌘Z restores your edit)")
            }
        }
    }

    /// The working artboard written back into its thumbnail page (rev-checked like scenes: if the AI saved the page
    /// first, theirs wins and our edit stays in undo).
    private func saveArtboard(_ pid: String, _ aid: String) {
        guard let disk = store.thumbnails[pid], let ab = disk.artboard(aid) else { return }
        let stored = ab.asScene(thumbnail: pid, rev: disk.rev)
        guard scene != stored else { return }
        do {
            let diff = SceneDiff.diff(stored, scene)
            let saved = try store.save(
                artboardScene: scene, thumbnail: pid, artboard: aid, expectedRev: baseRev, summary: diff.summary,
                source: .editor)
            ActivityLog.append(
                ActivityEntry(
                    source: .editor, tool: "edit", scene: scene.id, summary: diff.summary,
                    changed: diff.all.isEmpty ? nil : diff.all, revBefore: disk.rev, revAfter: saved.rev,
                    write: true), project: url)
            baseRev = saved.rev
            var s = scene; s.rev = saved.rev
            if s != scene { scene = s }
            stamps = fileStamps()
        } catch {
            try? store.reload()
            if let p = store.thumbnails[pid], let a = p.artboard(aid) {
                undoStack.append(scene)
                scene = a.asScene(thumbnail: pid, rev: p.rev); baseRev = p.rev
                flash("Thumbnail changed outside the editor — reloaded (⌘Z restores your edit)")
            }
        }
    }

    func fileStamps() -> [String: Date] {
        var out: [String: Date] = [:]
        let fm = FileManager.default
        func list(_ dir: String) -> [URL] {
            (try? fm.contentsOfDirectory(at: url.appendingPathComponent(dir), includingPropertiesForKeys: nil)) ?? []
        }
        for f in [url.appendingPathComponent("project.json")] + list("scenes") {
            out[f.lastPathComponent] = (try? fm.attributesOfItem(atPath: f.path)[.modificationDate]) as? Date
        }
        for f in list("thumbnails") {
            out["thumbnails/" + f.lastPathComponent] =
                (try? fm.attributesOfItem(atPath: f.path)[.modificationDate]) as? Date
        }
        return out
    }

    /// Re-reads the activity feed when the log file changed (MCP calls append to it).
    func refreshActivity(force: Bool = false) {
        let f = ActivityLog.url(url)
        let stamp = (try? FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate]) as? Date
        guard force || stamp != activityStamp else { return }
        activityStamp = stamp
        // Usually a few lines were appended: read just those. A forced refresh, the first read, or a trimmed
        // file reads the tail of the whole log.
        if !force, activityOffset > 0, let more = ActivityLog.read(project: url, after: activityOffset) {
            activityOffset = more.offset
            guard !more.entries.isEmpty else { return }
            let known = Set(activity.suffix(64).map(\.id))
            let fresh = more.entries.filter { !known.contains($0.id) }
            guard !fresh.isEmpty else { return }
            activity = Array((activity + fresh).suffix(400))
            if fresh.contains(where: \.isAI) { agentActiveUntil = Date().addingTimeInterval(4) }
            return
        }
        let size = ActivityLog.size(project: url)
        let entries = ActivityLog.read(project: url, limit: 400)
        let known = Set(activity.map(\.id))
        let newAgentEntries = entries.contains { $0.isAI && !known.contains($0.id) }
        activity = entries
        activityOffset = size
        if newAgentEntries && !force { agentActiveUntil = Date().addingTimeInterval(4) }
    }

    func poll() {
        refreshActivity()
        guard savePending == nil, !inGesture else { return }
        let now = fileStamps()
        guard now != stamps else { return }
        stamps = now
        guard (try? store.reload()) != nil else { return }
        project = effectiveProject()
        switch target {
        case .none:
            // Something was created outside the editor (an agent's first scene or thumbnail): open it.
            let (s, t, rev) = EditorDocument.initialTarget(workspace, store: store)
            if t != .none { open(s, target: t, rev: rev) }
            objectWillChange.send()
            return
        case .artboard(let pid, let aid):
            pollArtboard(pid, aid)
            objectWillChange.send()
            return
        case .scene: break
        }
        if let disk = store.scenes[scene.id] {
            if disk.rev != baseRev {
                let diff = SceneDiff.diff(scene, disk)
                undoStack.append(scene)
                scene = disk; baseRev = disk.rev
                // keep @camera / @look
                if let sel = selection, !sel.hasPrefix("@"), disk.node(sel) == nil { selection = nil }
                multiSelection = multiSelection.filter { disk.node($0) != nil }
                flashLayers(Set(diff.added + diff.modified))
                let by = activity.last { $0.scene == disk.id && $0.revAfter == disk.rev }?.isAI == true ? "AI" : "disk"
                flash("Updated by \(by) · \(diff.summary)")
            }
        } else if let first = store.orderedScenes.first {
            switchTo(first)  // the open scene was deleted on disk: its history must not bring it back
        } else {
            open(EditorDocument.placeholderScene(), target: .none, rev: 0)
        }
        objectWillChange.send()
    }

    /// Live reload of the open artboard when its page changed on disk (an agent's thumbnail_apply).
    private func pollArtboard(_ pid: String, _ aid: String) {
        guard let p = store.thumbnails[pid] else {
            let (s, t, rev) = EditorDocument.initialTarget(.thumbnail, store: store)  // page deleted on disk
            open(s, target: t, rev: rev)
            return
        }
        guard p.rev != baseRev else { return }
        guard let a = p.artboard(aid) else { open(thumbnail: pid); return }  // artboard removed: show the page's first
        let disk = a.asScene(thumbnail: pid, rev: p.rev)
        let diff = SceneDiff.diff(scene, disk)
        if diff.isEmpty { baseRev = p.rev; scene = disk; return }  // another artboard of this page changed
        undoStack.append(scene)
        scene = disk; baseRev = p.rev
        if let sel = selection, !sel.hasPrefix("@"), disk.node(sel) == nil { selection = nil }
        multiSelection = multiSelection.filter { disk.node($0) != nil }
        flashLayers(Set(diff.added + diff.modified))
        let by = activity.last?.isAI == true ? "AI" : "disk"
        flash("Updated by \(by) · \(diff.summary)")
    }

    /// Highlights layers that changed outside the editor (layer list + viewport), fading after a moment.
    func flashLayers(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        flashIds = ids
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.flashIds == ids { self?.flashIds = [] }
        }
    }

    // MARK: History (per scene)

    func history() -> [ProjectStore.HistoryEntry] {
        switch target {
        case .scene(let id): return store.history(id)
        case .artboard(let pid, _): return store.thumbnailHistory(pid)
        case .none: return []
        }
    }

    /// A saved revision of what's open, as a scene: for an artboard, that artboard in that revision of its page.
    func snapshotScene(_ rev: Int) -> Scene? {
        switch target {
        case .scene(let id): return store.snapshot(id, rev: rev)
        case .artboard(let pid, let aid):
            return store.thumbnailSnapshot(pid, rev: rev)?.artboard(aid)?.asScene(thumbnail: pid)
        case .none: return nil
        }
    }

    /// Restores a saved revision as a new revision (nothing is lost; undoable).
    func restore(rev: Int) {
        guard let old = snapshotScene(rev) else { flash("Revision \(rev) is no longer kept"); return }
        edit { s in
            let r = s.rev; s = old; s.rev = r
        }
        saveNow()
        flash("Restored revision \(rev)")
    }

    // MARK: Editor state for MCP (`editor_state`)

    func stateChanged() {
        stateWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.writeState() }
        stateWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: w)
    }

    private func writeState() {
        let state: JSONValue = [
            "workspace": .string(workspace.rawValue),
            "scene": target.thumbnailId == nil && target != .none ? .string(scene.id) : .null,
            "thumbnail": target.thumbnailId.map { .string($0) } ?? .null,
            "artboard": target.artboardId.map { .string($0) } ?? .null,
            "selection": selection.map { .string($0) } ?? .null,
            "time": .number((time * 1000).rounded() / 1000), "playing": .bool(playing),
            "updated": .string(ISO8601DateFormatter().string(from: Date())),
        ]
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url.appendingPathComponent(".state.json"), options: .atomic)
        }
    }
}
