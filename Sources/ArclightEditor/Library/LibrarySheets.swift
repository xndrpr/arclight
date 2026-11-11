import AppKit
import ArclightCore
import SwiftUI

/// Presents library sheets (template gallery, save as template) on a document's window from anywhere:
/// the scenes list, the + Layer menu, the File menu.
@MainActor enum LibrarySheets {
    static func window(for doc: EditorDocument) -> NSWindow? {
        NSApp.windows.first { ($0.windowController as? EditorWindowController)?.doc === doc }
    }

    static func present<V: View>(_ doc: EditorDocument, size: CGSize, _ make: (@escaping () -> Void) -> V) {
        guard let parent = window(for: doc), parent.attachedSheet == nil else { return }
        let sheet = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView, .resizable],
            backing: .buffered, defer: false)
        sheet.minSize = NSSize(width: size.width * 0.8, height: size.height * 0.8)
        let close: () -> Void = { [weak parent, weak sheet] in if let sheet { parent?.endSheet(sheet) } }
        AppWindows.configure(sheet, content: make(close).themedRoot())
        parent.beginSheet(sheet)
    }

    static func templates(_ doc: EditorDocument, mode: TemplateGallery.Mode) {
        present(doc, size: CGSize(width: 980, height: 640)) { close in
            TemplateGallery(doc: doc, mode: mode, close: close)
        }
    }

    static func saveTemplate(_ doc: EditorDocument, scene id: String? = nil) {
        let s = doc.scenes.first { $0.id == (id ?? doc.scene.id) } ?? doc.scene
        present(doc, size: CGSize(width: 620, height: 640)) { close in
            SaveTemplateSheet(doc: doc, scene: s, close: close)
        }
    }
}

/// Bottom row of a library sheet: `info` on the left, Cancel (Esc) and the primary action (Return) on the right.
struct SheetFooter<Info: View>: View {
    let cancel: () -> Void
    let confirmTitle: String
    var confirmDisabled = false
    let confirm: () -> Void
    @ViewBuilder let info: Info

    var body: some View {
        HStack {
            info
            Spacer()
            Button("Cancel", action: cancel).buttonStyle(PillButtonStyle()).keyboardShortcut(.cancelAction)
            Button(confirmTitle, action: confirm)
                .buttonStyle(PillButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                .disabled(confirmDisabled)
        }
        .padding(12)
    }
}

/// File menu actions (wired in MainMenu.build).
extension EditorWindowController {
    @objc func newSceneFromTemplate(_ sender: Any?) { LibrarySheets.templates(doc, mode: .newScene) }
    @objc func saveSceneAsTemplate(_ sender: Any?) { LibrarySheets.saveTemplate(doc) }
    @objc func importAssets(_ sender: Any?) { doc.importAssetsWithPanel() }
}
