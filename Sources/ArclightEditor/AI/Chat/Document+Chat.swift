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
}
