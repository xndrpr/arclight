import AppKit

/// DaVinci Resolve–style transport and editing keys (see `Shortcuts.all`), from the app's key-down monitor.
/// Returns nil for every key it handled; command combos that aren't listed here go through the menu.
enum KeyCommands {
    static func handle(_ e: NSEvent) -> NSEvent? {
        let r = route(e)
        if e.keyCode == 49 { ClickTrace.key(e, handled: r == nil) }
        return r
    }

    private static func route(_ e: NSEvent) -> NSEvent? {
        // Space never falls through to AppKit unhandled (that's the system beep): it plays/stops the frontmost
        // project unless the user is typing, or a focused button/switch should press (keyboard navigation).
        if e.keyCode == 49, e.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            let fr = NSApp.keyWindow?.firstResponder
            if let t = fr as? NSTextView, t.isEditable { return e }
            if fr is NSButton || fr is NSPopUpButton || fr is NSSegmentedControl { return e }
            if NSApp.keyWindow?.sheetParent == nil, NSApp.keyWindow?.attachedSheet == nil,
                let wc = EditorWindowController.frontmost
            {
                if fr is NSText { NSApp.keyWindow?.makeFirstResponder(nil) }
                wc.doc.togglePlay()
            }
            return nil
        }
        guard let wc = EditorWindowController.frontmost else { return e }
        if NSApp.keyWindow?.attachedSheet != nil { return e }
        let doc = wc.doc
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let chars = (e.charactersIgnoringModifiers ?? "").lowercased()
        // In a text field everything goes to the field, except Esc, which ends editing. Only *editable* text: a
        // selectable read-only label that swallowed Space made AppKit beep.
        if let t = NSApp.keyWindow?.firstResponder as? NSTextView, t.isEditable {
            if e.keyCode == 53 {
                NotificationCenter.default.post(name: .escapeInTextField, object: t)  // renames: Esc cancels
                NSApp.keyWindow?.makeFirstResponder(nil)
                return nil
            }
            return e
        }
        if NSApp.keyWindow?.firstResponder is NSText { NSApp.keyWindow?.makeFirstResponder(nil) }
        // ⌘-arrows nudge the selected layers 1 px (⌘⇧ 10 px). ⌃-arrows are taken by macOS for Spaces.
        if mods.subtracting(.shift) == .command, (123...126).contains(e.keyCode) {
            let k: Double = mods.contains(.shift) ? 10 : 1
            let d: (Double, Double) =
                e.keyCode == 123 ? (-k, 0) : e.keyCode == 124 ? (k, 0) : e.keyCode == 125 ? (0, k) : (0, -k)
            return doc.nudge(dx: d.0, dy: d.1) ? nil : e
        }
        // Command shortcuts handled here so they work no matter which SwiftUI view has focus.
        if mods.contains(.command) && !mods.contains(.control) {
            switch (chars, mods.contains(.shift)) {
            case ("z", false): doc.undoLatest(); return nil
            case ("z", true): doc.redoLatest(); return nil
            case ("c", false): doc.copySelection(); return nil
            case ("x", false): doc.cutSelection(); return nil
            case ("v", false): doc.paste(); return nil
            case ("d", false): doc.duplicateSelection(); return nil
            case ("g", false): doc.groupSelection(); return nil
            case ("g", true): doc.ungroupSelection(); return nil
            case ("a", true): doc.selection = nil; return nil  // ⇧⌘A deselect all
            case ("l", false): doc.toggleLoop(); return nil
            case ("/", _), ("?", _): NotificationCenter.default.post(name: .showShortcuts, object: doc); return nil
            default: return e
            }
        }

        guard !mods.contains(.control) else { return e }
        let shift = mods.contains(.shift), opt = mods.contains(.option)
        switch e.keyCode {
        case 49: doc.togglePlay(); return nil  // space
        // ← (⌥ nudges keys)
        case 123: if opt, doc.nudgeSelectedKeys(-1) { return nil }; doc.step(shift ? -Int(doc.fps) : -1); return nil
        // → (⌥ nudges keys)
        case 124: if opt, doc.nudgeSelectedKeys(1) { return nil }; doc.step(shift ? Int(doc.fps) : 1); return nil
        case 126:
            if opt { doc.moveSelection(1) } else { doc.jumpKey(forward: false, node: doc.selection) }; return nil  // ↑
        case 125:
            if opt { doc.moveSelection(-1) } else { doc.jumpKey(forward: true, node: doc.selection) }; return nil  // ↓
        case 115: doc.playing = false; doc.time = 0; doc.setTimelineOffset(0); return nil  // home
        case 119: doc.playing = false; doc.time = doc.scene.duration; return nil  // end
        case 51, 117: if !doc.deleteSelectedKeys() { doc.deleteSelection() }; return nil  // delete: selected keys first
        case 53:  // esc
            if AIPanelState.handleEscape(in: NSApp.keyWindow) { return nil }
            if doc.cinema {
                wc.setCinema(false)
            } else if doc.viewerOnly {
                doc.viewerOnly = false
            } else {
                doc.selection = nil
            }
            return nil
        default: break
        }
        switch chars {
        case "j": doc.shuttle(-1)
        case "k": doc.shuttle(0)
        case "l": doc.shuttle(1)
        case "i": doc.setInOut(isIn: true)
        case "o": doc.setInOut(isIn: false)
        case "x" where opt: doc.clearInOut()
        case "d": doc.toggleEnabled()
        case "m" where !shift && !opt: doc.addMarkerAtPlayhead()
        case "n": doc.snapping.toggle(); doc.flash("Snapping \(doc.snapping ? "on" : "off")")
        case "z" where shift: doc.zoomToFit()
        case "p": wc.setCinema(!doc.cinema)
        case "f" where shift: wc.setCinema(!doc.cinema)
        case "?": NotificationCenter.default.post(name: .showShortcuts, object: doc)
        default: return e
        }
        return nil
    }
}
