import AppKit
import ArclightCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var initialPath: String?
    private var windows: [EditorWindowController] = [] { didSet { publishPresence() } }
    private var welcome: NSWindow?
    private var newProjectWindow: NSWindow?
    private var newProjectCloseObserver: NSObjectProtocol?
    private var settingsWindow: NSWindow?
    private var installHelpWindow: NSWindow?
    private var keyMonitor: LocalEventMonitor?
    private var defaultsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppTheme.apply(AppTheme.stored)
        // A theme saved by anyone (`defaults write`, another process) reaches every window.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            AppTheme.syncFromDefaults()
        }
        NSApp.mainMenu = MainMenu.build()
        ScrollClickGuard.install()
        ClickTrace.installIfEnabled()
        // The handler's result goes straight back: nil swallows the key. `?? e` here passed handled keys on to the
        // window too, so Space played/stopped *and* beeped.
        let monitor = LocalEventMonitor(.keyDown) { e in KeyCommands.handle(e) }
        monitor.install()
        keyMonitor = monitor
        if let p = initialPath { open(URL(fileURLWithPath: (p as NSString).expandingTildeInPath)) }
        if windows.isEmpty { showWelcome() }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls { open(u) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showWelcome() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        for w in windows { w.doc.saveNow() }
        // After any queued write, so a late one can't bring the list back.
        Self.presenceQueue.sync { Presence.write(EditorPresence(pid: getpid(), projects: [])) }
    }

    /// Tells MCP servers which projects this editor has open (`editor_state` reports whether the user is watching).
    private func publishPresence() {
        let paths = windows.map { Presence.key($0.doc.url) }
        // One serial queue: writes land in the order the window list changed, so the file ends with the latest
        // list (on a concurrent queue an older write could finish last).
        Self.presenceQueue.async { Presence.write(EditorPresence(pid: getpid(), projects: paths)) }
    }

    private static let presenceQueue = DispatchQueue(label: "arclight.presence", qos: .utility)

    // MARK: Windows

    func open(_ url: URL) {
        if let existing = windows.first(where: { $0.doc.url.standardizedFileURL == url.standardizedFileURL }) {
            existing.window?.makeKeyAndOrderFront(nil); return
        }
        do {
            let doc = try EditorDocument(url: url)
            let wc = EditorWindowController(doc: doc) { [weak self] wc in self?.windows.removeAll { $0 === wc } }
            windows.append(wc)
            wc.showWindow(nil)
            welcome?.close(); welcome = nil
        } catch {
            let a = NSAlert(); a.messageText = "Could not open project"; a.informativeText = "\(error)"; a.runModal()
        }
    }

    func showWelcome() {
        if let w = welcome { w.makeKeyAndOrderFront(nil); return }
        welcome = AppWindows.open(
            width: 620, height: 420,
            content: WelcomeView(
                open: { [weak self] in self?.openDocument(nil) },
                new: { [weak self] in self?.newDocument(nil) },
                openURL: { [weak self] u in self?.open(u) }
            ).themedRoot())
    }

    func goHome(from wc: EditorWindowController) {
        wc.doc.saveNow()
        wc.close()
        showWelcome()
    }

    // MARK: Menu actions

    @objc func openDocument(_ sender: Any?) {
        if let u = FilePicker.project(message: "Choose an .arclight project") { open(u) }
    }

    /// ⌘N — the New Project window: name, location, canvas, frame rate and a starting template.
    @objc func newDocument(_ sender: Any?) {
        if let w = newProjectWindow { w.makeKeyAndOrderFront(nil); return }
        let w = AppWindows.open(
            width: 940, height: 600, resizable: true, title: "New Project",
            content: NewProjectView(
                create: { [weak self] u in
                    self?.newProjectWindow?.close(); self?.newProjectWindow = nil; self?.open(u)
                },
                cancel: { [weak self] in
                    self?.newProjectWindow?.close(); self?.newProjectWindow = nil
                }
            )
            .themedRoot())
        newProjectWindow = w
        // Closed with the red button: forget it too, so ⌘N opens a fresh form instead of the closed window.
        // (No queue: runs synchronously while the window closes, on the main thread.)
        newProjectCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: w, queue: nil
        ) { [weak self, weak w] _ in
            guard let self else { return }
            if self.newProjectWindow === w { self.newProjectWindow = nil }
            if let o = self.newProjectCloseObserver { NotificationCenter.default.removeObserver(o) }
            self.newProjectCloseObserver = nil
        }
    }

    /// ⌘, — settings for the frontmost project (or editor-only settings from the home screen).
    @objc func showSettings(_ sender: Any?) {
        let doc =
            (NSApp.keyWindow?.windowController as? EditorWindowController)?.doc
            ?? (NSApp.mainWindow?.windowController as? EditorWindowController)?.doc
            ?? windows.first?.doc
        settingsWindow?.close()
        settingsWindow = AppWindows.open(
            width: 640, height: 560, title: doc.map { "Settings — \($0.project.name)" } ?? "Settings",
            background: .panel, content: SettingsView(doc: doc))
    }

    /// Help ▸ Install & Security Guide…: keeping macOS from blocking or trashing the unsigned app.
    @objc func showInstallHelp(_ sender: Any?) {
        installHelpWindow?.close()
        installHelpWindow = AppWindows.open(
            width: 560, height: 560, title: "Install & Security", background: .panel,
            content: InstallHelpView(close: { [weak self] in self?.installHelpWindow?.close() }).themedRoot())
    }

    /// Shows "Version 0.1.0 (alpha)" whether or not the app runs from a bundle with an Info.plist.
    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Arclight", .applicationVersion: ArclightVersion.number,
            .version: ArclightVersion.stage,
        ])
    }

    @objc func toggleAIPanel(_ sender: Any?) { AIPanelState.toggle() }

    /// View ▸ App Theme: switches the editor's colours (all windows update live).
    @objc func setAppTheme(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let t = AppTheme(rawValue: raw) else { return }
        AppTheme.apply(t)
        sender.menu?.items.forEach { $0.state = ($0.representedObject as? String) == raw ? .on : .off }
    }

    @objc func toggleClickTrace(_ sender: NSMenuItem) { ClickTrace.enabled.toggle() }

    @objc func showClickLog(_ sender: Any?) {
        if FileManager.default.fileExists(atPath: ClickTrace.logURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([ClickTrace.logURL])
        }
    }
}

extension AppDelegate: NSMenuItemValidation {
    /// Keeps the Click Diagnostics and App Theme checkmarks in sync (the theme can also change in Settings).
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleClickTrace(_:)) { item.state = ClickTrace.enabled ? .on : .off }
        if item.action == #selector(setAppTheme(_:)) {
            item.state = (item.representedObject as? String) == AppTheme.current.rawValue ? .on : .off
        }
        return true
    }
}
