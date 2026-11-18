import ArclightCore
import Foundation

extension EditorDocument {
    /// The short note on what the editor shows, sent at the start of each chat message so "this" and "the selected
    /// layer" mean what the user sees.
    func chatNote() -> String {
        let open: String?
        switch target {
        case .scene(let id): open = "scene \(id)"
        case .artboard(let t, let a): open = "thumbnail \(t), artboard \(a)"
        case .none: open = nil
        }
        return ChatPrompt.editorNote(
            workspace: workspace.rawValue, target: open, selection: selectedIds.sorted(),
            time: workspace == .motion ? time : nil)
    }

    /// Every scene's revision right now: what a chat turn starts from.
    func chatCheckpoint() -> [String: Int] {
        saveNow()
        _ = try? store.reload()
        return store.scenes.mapValues(\.rev)
    }

    /// Puts back every scene that changed since `checkpoint` (each as a new revision, so History still has what the
    /// AI made). Returns the scenes put back. Scenes made since then stay.
    @discardableResult func revertChat(to checkpoint: [String: Int]) -> [String] {
        saveNow()
        _ = try? store.reload()
        var done: [String] = []
        for (id, rev) in checkpoint.sorted(by: { $0.key < $1.key }) {
            guard let cur = store.scenes[id], cur.rev != rev else { continue }
            if case .scene(let open) = target, open == id {
                guard snapshotScene(rev) != nil else { continue }
                restore(rev: rev)
                done.append(id)
            } else if let old = store.snapshot(id, rev: rev),
                (try? store.save(scene: old, summary: "Revert chat turn", source: .editor)) != nil
            {
                done.append(id)
            }
        }
        stamps = fileStamps()
        objectWillChange.send()
        flash(done.isEmpty ? "Nothing to put back" : "Put back \(done.count) scene\(done.count == 1 ? "" : "s")")
        return done
    }
}
