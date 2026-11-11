import AppKit

/// The menu bar. Actions go up the responder chain: the key `EditorWindowController` first, then `AppDelegate`.
/// Single-key shortcuts (handled by `KeyCommands`) are shown in the titles, not as key equivalents.
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            host.submenu = m
            main.addItem(host)
        }
        typealias W = EditorWindowController
        submenu(
            "Arclight",
            [
                item("About Arclight", #selector(AppDelegate.showAbout(_:))),
                .separator(),
                item("Settings…", #selector(AppDelegate.showSettings(_:)), ","),
                .separator(),
                item("Hide Arclight", #selector(NSApplication.hide(_:)), "h"),
                item("Quit Arclight", #selector(NSApplication.terminate(_:)), "q"),
            ])
        submenu(
            "File",
            [
                item("New Project…", #selector(AppDelegate.newDocument(_:)), "n"),
                item("Open Project…", #selector(AppDelegate.openDocument(_:)), "o"),
                item("Projects", #selector(W.goHome(_:)), "h", [.command, .shift]),
                .separator(),
                item("New Scene", #selector(W.newScene(_:)), "n", [.command, .shift]),
                item("New Scene from Template…", #selector(W.newSceneFromTemplate(_:)), "n", [.command, .option]),
                item(
                    "Save Scene as Template…", #selector(W.saveSceneAsTemplate(_:)), "s", [.command, .option, .shift]),
                item("Import Assets…", #selector(W.importAssets(_:)), "i", [.command, .shift]),
                item("Rename Project…", #selector(W.renameProject(_:)), ""),
                item("Save", #selector(W.saveDocument(_:)), "s"),
                item("Export…", #selector(W.exportDocument(_:)), "e"),
                item("Show in Finder", #selector(W.revealProject(_:)), "r", [.command, .shift]),
                .separator(),
                item("Close", #selector(NSWindow.performClose(_:)), "w"),
            ])
        submenu(
            "Edit",
            [
                item("Undo", #selector(W.undo(_:)), "z"),
                item("Redo", #selector(W.redo(_:)), "z", [.command, .shift]),
                .separator(),
                item("Cut", #selector(NSText.cut(_:)), "x"),
                item("Copy", #selector(NSText.copy(_:)), "c"),
                item("Paste", #selector(NSText.paste(_:)), "v"),
                item("Select All", #selector(NSText.selectAll(_:)), "a"),
                .separator(),
                item("Duplicate", #selector(W.duplicateLayer(_:)), "d"),
                item("Group", #selector(W.groupLayers(_:)), "g"),
                item("Ungroup", #selector(W.ungroupLayers(_:)), "g", [.command, .shift]),
                item("Clear Keyframes on Layer", #selector(W.clearKeyframes(_:)), ""),
            ])
        submenu(
            "Timeline",
            [
                item("Zoom In", #selector(W.zoomIn(_:)), "="),
                item("Zoom Out", #selector(W.zoomOut(_:)), "-"),
                item("Zoom to Fit                ⇧Z", #selector(W.zoomFit(_:)), ""),
                .separator(),
                item("Snapping                    N", #selector(W.toggleSnapping(_:)), ""),
            ])
        submenu(
            "View",
            [
                item("Viewer Only", #selector(W.toggleViewerOnly(_:)), "f"),
                item("Cinema Viewer             P", #selector(W.toggleCinema(_:)), "f", [.command, .shift]),
                item("Performance Mode", #selector(W.togglePerformance(_:)), "p", [.command, .shift]),
                .separator(),
                item("AI Panel", #selector(W.toggleAIPanel(_:)), "a", [.command, .option]),
                appThemeMenu(),
                .separator(),
                item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
            ])
        submenu(
            "Help",
            [
                item("Keyboard Shortcuts", #selector(W.showShortcuts(_:)), "?"),
                .separator(),
                item("Install & Security Guide…", #selector(AppDelegate.showInstallHelp(_:)), ""),
                .separator(),
                item("Record Click Diagnostics", #selector(AppDelegate.toggleClickTrace(_:)), ""),
                item("Show Click Log", #selector(AppDelegate.showClickLog(_:)), ""),
            ])
        return main
    }

    private static func item(
        _ title: String, _ action: Selector?, _ key: String = "",
        _ mods: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        return i
    }

    /// View ▸ App Theme, one item per theme.
    private static func appThemeMenu() -> NSMenuItem {
        let m = NSMenuItem(title: "App Theme", action: nil, keyEquivalent: "")
        let sub = NSMenu(title: "App Theme")
        for t in AppTheme.allCases {
            let i = NSMenuItem(title: t.title, action: #selector(AppDelegate.setAppTheme(_:)), keyEquivalent: "")
            i.representedObject = t.rawValue
            i.state = t == AppTheme.current ? .on : .off
            sub.addItem(i)
        }
        m.submenu = sub
        return m
    }
}
