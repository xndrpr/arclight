import AppKit
import ArclightCore

/// DaVinci Resolve–style transport and editing keys (see `Shortcuts.all`), from the app's key-down monitor.
/// Returns nil for every key it handled; command combos that aren't listed here go through the menu.
enum KeyCommands {
    static func handle(_ e: NSEvent) -> NSEvent? {
        let r = route(e)
        if e.keyCode == 49 { ClickTrace.key(e, handled: r == nil) }
        return r
    }

    /// The tool to return to when a held Space (temporary Hand) is released.
    private static var springTool: ThumbnailTool?

    static func handleUp(_ e: NSEvent) -> NSEvent? {
        if e.keyCode == 49, let t = springTool {
            springTool = nil
            EditorWindowController.frontmost?.doc.tool = t
            return nil
        }
        return e
    }

    private static func route(_ e: NSEvent) -> NSEvent? {
        // Space never falls through to AppKit unhandled (that's the system beep): it plays/stops the frontmost
        // project unless the user is typing, or a focused button/switch should press (keyboard navigation).
        if e.keyCode == 49, e.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            let fr = NSApp.keyWindow?.firstResponder
            // Thumbnail: hold Space for the Hand tool (Figma / Photoshop); released in `handleUp`.
            if let wc = EditorWindowController.frontmost, wc.doc.isThumbnail,
                !(fr is NSTextView && (fr as? NSTextView)?.isEditable == true),
                NSApp.keyWindow?.attachedSheet == nil
            {
                if !e.isARepeat, wc.doc.tool != .hand { springTool = wc.doc.tool; wc.doc.tool = .hand }
                return nil
            }
            if let t = fr as? NSTextView, t.isEditable { return e }
            if fr is NSButton || fr is NSPopUpButton || fr is NSSegmentedControl { return e }
            if NSApp.keyWindow?.sheetParent == nil, NSApp.keyWindow?.attachedSheet == nil,
                let wc = EditorWindowController.frontmost
            {
                if fr is NSText { NSApp.keyWindow?.makeFirstResponder(nil) }
                if !wc.doc.isThumbnail { wc.doc.togglePlay() }  // thumbnails are stills
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
        // Selectable text (chat messages, tool output): ⌘C copies the selected words and ⌘A selects them, instead of
        // copying layers.
        if let t = NSApp.keyWindow?.firstResponder as? NSTextView, t.isSelectable, mods == .command,
            (chars == "c" && t.selectedRange().length > 0) || chars == "a"
        {
            return e
        }
        // Working in the AI panel (last click was inside it): ⌘C / ⌘A go to the text there, not the layers.
        if mods == .command, chars == "c" || chars == "a", FloatingRegions.isFocused(NSApp.keyWindow) { return e }
        if NSApp.keyWindow?.firstResponder is NSText { NSApp.keyWindow?.makeFirstResponder(nil) }
        // ⌘-arrows nudge the selected layers 1 px (⌘⇧ 10 px). ⌃-arrows are taken by macOS for Spaces.
        if mods.subtracting(.shift) == .command, (123...126).contains(e.keyCode) {
            let k: Double = mods.contains(.shift) ? 10 : 1
            let d: (Double, Double) =
                e.keyCode == 123 ? (-k, 0) : e.keyCode == 124 ? (k, 0) : e.keyCode == 125 ? (0, k) : (0, -k)
            return doc.nudge(dx: d.0, dy: d.1) ? nil : e
        }
        // Thumbnail workspace: Figma / Photoshop command keys first (they differ from the Resolve-style motion map).
        if doc.isThumbnail, thumbnailCommand(e, doc: doc, mods: mods) { return nil }
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
            case ("1", false): doc.setWorkspace(.motion); return nil
            case ("2", false): doc.setWorkspace(.thumbnail); return nil
            default: return e
            }
        }

        // Thumbnail workspace: stills, so no transport or timeline keys. Arrows nudge layers (Figma: 1 px, ⇧ 10 px).
        if doc.isThumbnail { return thumbnailKey(e, doc: doc, wc: wc, mods: mods) }

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

    /// ⌘ shortcuts of the Thumbnail workspace (Figma first, Photoshop where Figma has none). True if handled.
    private static func thumbnailCommand(_ e: NSEvent, doc: EditorDocument, mods: NSEvent.ModifierFlags) -> Bool {
        guard mods.contains(.command), !mods.contains(.control) else { return false }
        let chars = (e.charactersIgnoringModifiers ?? "").lowercased()
        let shift = mods.contains(.shift), opt = mods.contains(.option)
        switch (chars, shift, opt) {
        case ("j", false, false): doc.duplicateSelection()  // Photoshop: duplicate layer
        case ("]", false, false): doc.moveSelection(1)  // bring forward
        case ("[", false, false): doc.moveSelection(-1)  // send backward
        case ("]", false, true), ("}", _, true): doc.arrange(toFront: true)
        case ("[", false, true), ("{", _, true): doc.arrange(toFront: false)
        case ("h", true, false): doc.toggleEnabled()  // Figma: show / hide
        case ("l", true, false):  // Figma: lock / unlock
            guard let id = doc.selection else { return true }
            doc.setLocked(doc.targets(id), !doc.isLockedDirect(id))
        case ("k", true, false): doc.placeImage(at: nil)  // Figma: place image
        case ("k", false, false): doc.aiPrompt = .generate  // AI: generate an image
        case ("f", true, false):  // Photoshop: generative fill on the marquee
            if doc.marquee != nil { doc.aiPrompt = .fill } else { doc.flash("Draw a marquee first (M)") }
        case ("b", false, true): doc.removeBackground()  // AI: remove background (on-device)
        case ("=", _, false), ("+", _, false): doc.postBoard(.zoomIn)
        case ("-", _, false): doc.postBoard(.zoomOut)
        case ("0", false, false): doc.postBoard(.actualSize)
        case ("l", false, false): return true  // no loop in Thumbnail
        default: return false
        }
        return true
    }

    /// Plain keys of the Thumbnail workspace: tools (V T R O L H Z), view (⇧0 ⇧1 ⇧2), artboards (A/F), nudges.
    private static func thumbnailKey(
        _ e: NSEvent, doc: EditorDocument, wc: EditorWindowController, mods: NSEvent.ModifierFlags
    ) -> NSEvent? {
        guard mods.intersection([.control, .option, .command]).isEmpty else { return e }
        let shift = mods.contains(.shift)
        switch e.keyCode {
        case 123...126:
            let k: Double = shift ? 10 : 1
            let d: (Double, Double) =
                e.keyCode == 123 ? (-k, 0) : e.keyCode == 124 ? (k, 0) : e.keyCode == 125 ? (0, k) : (0, -k)
            return doc.nudge(dx: d.0, dy: d.1) ? nil : e
        case 51, 117: doc.deleteSelection(); return nil  // delete
        case 53:  // esc: AI panel, cinema, the active tool, then the selection
            if AIPanelState.handleEscape(in: NSApp.keyWindow) { return nil }
            if doc.cinema {
                wc.setCinema(false)
            } else if doc.viewerOnly {
                doc.viewerOnly = false
            } else if doc.aiPrompt != nil {
                doc.aiPrompt = nil
            } else if doc.marquee != nil {
                doc.marquee = nil
            } else if doc.tool != .move {
                doc.tool = .move
            } else {
                doc.selection = nil; doc.multiSelection = []
            }
            return nil
        case 49: return nil  // space: nothing to play (space-drag pans)
        default: break
        }
        // ⇧0 / ⇧1 / ⇧2 arrive as ")", "!", "@" on US layouts: read the key code.
        if shift {
            switch e.keyCode {
            case 29: doc.postBoard(.actualSize); return nil  // ⇧0: 100%
            case 18: doc.postBoard(.fitAll); return nil  // ⇧1: zoom to fit all artboards
            case 19: doc.postBoard(.fitArtboard); return nil  // ⇧2: zoom to the open artboard
            default: break
            }
        }
        switch (e.charactersIgnoringModifiers ?? "").lowercased() {
        case "v": doc.tool = .move
        case "m": doc.tool = .marquee
        case "w": doc.selectSubject()
        case "t": doc.tool = .text
        case "r": doc.tool = .rect
        case "o": doc.tool = .ellipse
        case "l": doc.tool = .line
        case "h": doc.tool = .hand
        case "z": doc.tool = .zoom
        case "a", "f":  // Figma's frame / artboard key: a new artboard like this one, to the right
            if let a = doc.target.artboardId, let p = doc.target.thumbnailId,
                let ab = doc.openThumbnail?.artboard(a)
            {
                doc.addArtboard(
                    preset: ArtboardPresets.all.first { $0.size == ab.size }
                        ?? .init(id: "artboard", title: "Artboard", size: ab.size), to: p)
            }
        case "p": wc.setCinema(!doc.cinema)
        case "?": NotificationCenter.default.post(name: .showShortcuts, object: doc)
        default: return e
        }
        return nil
    }
}
