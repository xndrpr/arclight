import ArclightCore
import Foundation

/// Undo history for project theme edits (the scene undo stack only holds scene snapshots). One per document
/// (`EditorDocument.themeHistory`), so it lives and dies with it.
final class ThemeHistory {
    var undo: [[String: JSONValue]] = []
    var redo: [[String: JSONValue]] = []
    /// Last single-token edit (key, time): quick successive edits of one token (colour panel drags) coalesce.
    var last: (key: String, at: Date)?
    /// Scene as it was at the latest theme edit: if the scene hasn't changed since, ⌘Z undoes the theme first.
    var sceneAtEdit: Scene?
    /// True right after a theme undo, so ⌘⇧Z redoes the theme first.
    var lastUndoWasTheme = false
}

extension EditorDocument {
    var canUndoTheme: Bool { !themeHistory.undo.isEmpty }
    var canRedoTheme: Bool { !themeHistory.redo.isEmpty }

    /// Replaces the whole project theme as one undoable step.
    func replaceTheme(_ theme: [String: JSONValue], coalesceKey: String? = nil) {
        let old = project.theme
        guard theme != old else { return }
        let h = themeHistory
        let now = Date()
        let coalesce = coalesceKey != nil && h.last?.key == coalesceKey && now.timeIntervalSince(h.last!.at) < 1.0
        if !coalesce {
            h.undo.append(old)
            if h.undo.count > 100 { h.undo.removeFirst() }
        }
        h.redo.removeAll()
        h.last = coalesceKey.map { ($0, now) }
        h.sceneAtEdit = scene; h.lastUndoWasTheme = false
        writeTheme(theme)
    }

    /// Sets (or with nil removes) one token, undoably.
    func setThemeToken(_ key: String, _ value: JSONValue?) {
        var t = project.theme
        t[key] = value
        replaceTheme(t, coalesceKey: value == nil ? nil : key)
    }

    /// Applies a preset: its tokens replace the matching ones, custom extra tokens stay.
    func applyThemePreset(_ preset: ThemePreset) {
        replaceTheme(ThemePresets.applying(preset, to: project.theme))
        flash("Theme: \(preset.name)")
    }

    /// ⌘Z: undoes whichever happened last, a theme edit or a scene edit.
    func undoLatest() {
        let h = themeHistory
        if canUndoTheme, !canUndo || h.sceneAtEdit == scene {
            undoTheme(); h.lastUndoWasTheme = true
        } else {
            undo(); h.lastUndoWasTheme = false
        }
    }

    /// ⇧⌘Z: redoes in the reverse order of `undoLatest`.
    func redoLatest() {
        let h = themeHistory
        if canRedoTheme, !canRedo || h.lastUndoWasTheme { redoTheme(); h.sceneAtEdit = scene } else { redo() }
    }

    @discardableResult
    func undoTheme() -> Bool {
        let h = themeHistory
        guard let prev = h.undo.popLast() else { return false }
        h.redo.append(project.theme); h.last = nil
        writeTheme(prev)
        flash("Theme change undone")
        return true
    }

    @discardableResult
    func redoTheme() -> Bool {
        let h = themeHistory
        guard let next = h.redo.popLast() else { return false }
        h.undo.append(project.theme); h.last = nil
        writeTheme(next)
        return true
    }

    /// The preset the current theme matches, if any.
    var currentThemePreset: ThemePreset? { ThemePresets.current(project.theme) }

    /// The colours to show for the theme in compact previews: background, text, accent, then pool/muted.
    var themeSwatchColors: [String] {
        let t = project.theme
        return ["bg", "fg", "accent", "muted", "pool"].compactMap { k in
            t[k]?.string.flatMap { RGBA.parse(.string($0)) != nil ? $0 : nil }
        }
    }

    private func writeTheme(_ theme: [String: JSONValue]) {
        var p = store.project
        p.theme = theme
        do { try store.update(project: p) } catch { flash("Couldn't save the theme: \(error.localizedDescription)") }
        refreshProject()
    }
}
