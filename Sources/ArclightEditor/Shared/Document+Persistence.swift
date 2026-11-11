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

    func fileStamps() -> [String: Date] {
        var out: [String: Date] = [:]
        let fm = FileManager.default
        let files =
            [url.appendingPathComponent("project.json")]
            + ((try? fm.contentsOfDirectory(at: url.appendingPathComponent("scenes"), includingPropertiesForKeys: nil))
                ?? [])
        for f in files {
            out[f.lastPathComponent] = (try? fm.attributesOfItem(atPath: f.path)[.modificationDate]) as? Date
        }
        return out
    }

    /// Re-reads the activity feed when the log file changed (MCP calls append to it).
    func refreshActivity(force: Bool = false) {
        let f = ActivityLog.url(url)
        let stamp = (try? FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate]) as? Date
        guard force || stamp != activityStamp else { return }
        activityStamp = stamp
        let entries = ActivityLog.read(project: url, limit: 400)
        let newAgentEntries = entries.filter { $0.isAI && !activity.map(\.id).contains($0.id) }
        activity = entries
        if !newAgentEntries.isEmpty && !force { agentActiveUntil = Date().addingTimeInterval(4) }
    }

    func poll() {
        refreshActivity()
        guard savePending == nil, !inGesture else { return }
        let now = fileStamps()
        guard now != stamps else { return }
        stamps = now
        guard (try? store.reload()) != nil else { return }
        project = store.project
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
        }
        objectWillChange.send()
    }

    /// Highlights layers that changed outside the editor (layer list + viewport), fading after a moment.
    private func flashLayers(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        flashIds = ids
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.flashIds == ids { self?.flashIds = [] }
        }
    }

    // MARK: History (per scene)

    func history() -> [ProjectStore.HistoryEntry] { store.history(scene.id) }

    /// Restores a saved revision as a new revision (nothing is lost; undoable).
    func restore(rev: Int) {
        guard let old = store.snapshot(scene.id, rev: rev) else { flash("Revision \(rev) is no longer kept"); return }
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
            "scene": .string(scene.id), "selection": selection.map { .string($0) } ?? .null,
            "time": .number((time * 1000).rounded() / 1000), "playing": .bool(playing),
            "updated": .string(ISO8601DateFormatter().string(from: Date())),
        ]
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: url.appendingPathComponent(".state.json"), options: .atomic)
        }
    }
}
