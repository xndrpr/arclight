import AppKit
import ArclightCore
import SwiftUI

/// One window per project.
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let doc: EditorDocument
    private let onClose: (EditorWindowController) -> Void
    private var cinemaMadeFullScreen = false

    /// The editor in the key window, else in the main window.
    static var frontmost: EditorWindowController? {
        (NSApp.keyWindow?.windowController ?? NSApp.mainWindow?.windowController) as? EditorWindowController
    }

    init(doc: EditorDocument, onClose: @escaping (EditorWindowController) -> Void) {
        self.doc = doc
        self.onClose = onClose
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1480, height: 920), styleMask: AppWindows.editorStyle,
            backing: .buffered, defer: false)
        w.minSize = NSSize(width: 1100, height: 680)
        w.title = doc.project.name
        w.representedURL = doc.url
        w.setFrameAutosaveName("arclight.editor")
        super.init(window: w)
        w.delegate = self
        w.collectionBehavior.insert(.fullScreenPrimary)
        AppWindows.configure(w, content: EditorView(doc: doc))
        AppWindows.addTitlebarToolbar(to: w, identifier: "arclight.editor")
        doc.onCinemaChange = { [weak self] on in self?.setCinema(on) }
        if !w.setFrameUsingName("arclight.editor") { w.center() }
        if let out = ProcessInfo.processInfo.environment["ARCLIGHT_SNAPSHOT"] { scheduleSnapshot(out) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        doc.saveNow()
        onClose(self)
    }

    // MARK: Menu actions

    @objc func undo(_ sender: Any?) { doc.undoLatest() }
    @objc func redo(_ sender: Any?) { doc.redoLatest() }
    @objc func copy(_ sender: Any?) { doc.copySelection() }
    @objc func cut(_ sender: Any?) { doc.cutSelection() }
    @objc func paste(_ sender: Any?) { doc.paste() }
    @objc func duplicateLayer(_ sender: Any?) { doc.duplicateSelection() }
    @objc func clearKeyframes(_ sender: Any?) { if let id = doc.selection { doc.clearAllAnimation(id) } }
    @objc func newScene(_ sender: Any?) { doc.newScene() }
    @objc func saveDocument(_ sender: Any?) { doc.saveNow(); doc.flash("Saved") }
    @objc func togglePerformance(_ sender: Any?) { doc.performance.toggle() }
    @objc func toggleAIPanel(_ sender: Any?) { AIPanelState.toggle() }
    @objc func toggleViewerOnly(_ sender: Any?) { doc.viewerOnly.toggle() }
    @objc func toggleCinema(_ sender: Any?) { setCinema(!doc.cinema) }
    @objc func zoomIn(_ sender: Any?) { doc.zoomTimeline(by: 1.5) }
    @objc func zoomOut(_ sender: Any?) { doc.zoomTimeline(by: 1 / 1.5) }
    @objc func zoomFit(_ sender: Any?) { doc.zoomToFit() }
    @objc func toggleSnapping(_ sender: Any?) { doc.snapping.toggle() }
    @objc func showShortcuts(_ sender: Any?) { NotificationCenter.default.post(name: .showShortcuts, object: doc) }
    @objc func renameProject(_ sender: Any?) { NotificationCenter.default.post(name: .renameProject, object: doc) }
    @objc func revealProject(_ sender: Any?) { NSWorkspace.shared.activateFileViewerSelecting([doc.url]) }
    @objc func exportDocument(_ sender: Any?) { NotificationCenter.default.post(name: .showExport, object: doc) }
    @objc func goHome(_ sender: Any?) { (NSApp.delegate as? AppDelegate)?.goHome(from: self) }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return doc.canUndo || doc.canUndoTheme
        case #selector(redo(_:)): return doc.canRedo || doc.canRedoTheme
        case #selector(copy(_:)), #selector(cut(_:)), #selector(duplicateLayer(_:)), #selector(clearKeyframes(_:)):
            return doc.selection != nil
        case #selector(togglePerformance(_:)): item.state = doc.performance ? .on : .off; return true
        case #selector(toggleAIPanel(_:)):
            item.state = Pref.store.bool(forKey: Pref.aiPanel) ? .on : .off; return true
        case #selector(toggleViewerOnly(_:)): item.state = doc.viewerOnly ? .on : .off; return true
        case #selector(toggleCinema(_:)): item.state = doc.cinema ? .on : .off; return true
        case #selector(toggleSnapping(_:)): item.state = doc.snapping ? .on : .off; return true
        default: return true
        }
    }

    // MARK: Cinema

    /// Cinema viewer: viewport only, window full screen. Esc / P exits.
    func setCinema(_ on: Bool) {
        guard let w = window, doc.cinema != on else { return }
        doc.cinema = on
        let isFull = w.styleMask.contains(.fullScreen)
        if on && !isFull { cinemaMadeFullScreen = true; w.toggleFullScreen(nil) }
        if !on && isFull && cinemaMadeFullScreen { cinemaMadeFullScreen = false; w.toggleFullScreen(nil) }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if doc.cinema { cinemaMadeFullScreen = false; doc.cinema = false }
    }

    // MARK: Debug snapshot of the real window

    /// ARCLIGHT_SNAPSHOT=out.png [ARCLIGHT_SNAPSHOT_TIME=3.6] [ARCLIGHT_SNAPSHOT_SELECT=id] [ARCLIGHT_SNAPSHOT_ZOOM=2]
    /// [ARCLIGHT_SNAPSHOT_PANEL=settings|shortcuts] [ARCLIGHT_SNAPSHOT_QUIT=1]: writes a PNG of this on-screen window
    /// (`arclight snapshot` does the same off-screen).
    private func scheduleSnapshot(_ out: String) {
        let env = ProcessInfo.processInfo.environment
        let url = URL(fileURLWithPath: out)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
            if let t = env["ARCLIGHT_SNAPSHOT_TIME"].flatMap(Double.init) { doc.time = t }
            if let s = env["ARCLIGHT_SNAPSHOT_SELECT"] { doc.selection = s }
            if let z = env["ARCLIGHT_SNAPSHOT_ZOOM"].flatMap(Double.init) { doc.zoomTimeline(by: z) }
            if let panel = env["ARCLIGHT_SNAPSHOT_PANEL"] {
                // A secondary panel (the settings window or the shortcuts sheet) instead of the editor.
                if panel == "settings" {
                    (NSApp.delegate as? AppDelegate)?.showSettings(nil)
                } else {
                    NotificationCenter.default.post(name: .showShortcuts, object: doc)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    let win =
                        panel == "settings"
                        ? NSApp.windows.first { $0.contentView is NSHostingView<SettingsView> }
                        : self.window?.attachedSheet
                    if let v = win?.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    }
                    if env["ARCLIGHT_SNAPSHOT_QUIT"] == "1" { NSApp.terminate(nil) }
                }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [self] in
                guard let w = window, let view = w.contentView,
                    let image = Offscreen.capture(view, in: w, size: view.bounds.size, doc: doc, time: doc.time)
                else { return }
                try? Offscreen.png(image)?.write(to: url)
                if env["ARCLIGHT_SNAPSHOT_QUIT"] == "1" { NSApp.terminate(nil) }
            }
        }
    }
}
