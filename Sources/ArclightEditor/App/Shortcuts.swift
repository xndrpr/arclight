import AppKit
import SwiftUI

/// Keyboard map, modelled on DaVinci Resolve's Edit page.
enum Shortcuts {
    typealias Group = (group: String, items: [(keys: [String], action: String)])

    static let left: [Group] = [
        (
            "Playback",
            [
                (["Space"], "Play / stop"),
                (["J", "K", "L"], "Shuttle back / stop / forward"),
                (["L", "L"], "Faster: 2× · 4× · 8×"),
                (["←", "→"], "Previous / next frame"),
                (["⇧←", "⇧→"], "Back / forward one second"),
                (["↑", "↓"], "Previous / next keyframe or edit"),
                (["Home", "End"], "Start / end"),
            ]
        ),
        (
            "Timeline",
            [
                (["⌥", "scroll"], "Zoom at pointer (or pinch)"),
                (["⇧", "scroll"], "Pan (or swipe sideways) — keeps going past END"),
                (["⌘=", "⌘−"], "Zoom in / out"),
                (["⇧Z"], "Zoom to fit"),
                (["N"], "Snapping on / off"),
                (["M"], "Add marker at playhead (double-click to rename)"),
                (["⌘L"], "Loop on / off"),
                (["⌥ drag ruler"], "Set work area (⌥ click clears)"),
                (["drag bar edge"], "Trim start / end without moving content"),
                (["⇧ click ◆", "⌥ drag"], "Select keyframes · box-select"),
                (["⌫", "⌥←", "⌥→"], "Delete / nudge selected keyframes"),
                (["drag END"], "Change scene duration (snaps to keys and markers)"),
                (["past END"], "Hatched, not rendered; the viewer shows the last frame"),
                (["key past END"], "Setting a key / layer start there extends the scene"),
                (["drag layer row"], "Reorder · drop on a group's middle to put it inside"),
            ]
        ),
        (
            "View",
            [
                (["pinch", "⌘ scroll"], "Zoom the canvas at the pointer"),
                (["scroll", "space drag"], "Pan the canvas"),
                (["⌥ drag", "⌥ scroll"], "Orbit / dolly the 3D camera"),
                (["P"], "Cinema viewer (full screen)"),
                (["⌘F"], "Viewer only"),
            ]
        ),
    ]

    static let right: [Group] = [
        (
            "Editing",
            [
                (["⌘Z", "⇧⌘Z"], "Undo / redo"),
                (["⌘C", "⌘X", "⌘V"], "Copy / cut / paste layers"),
                (["⌘D"], "Duplicate layer"),
                (["⌘G", "⇧⌘G"], "Group / ungroup selected layers"),
                (["⌘ click", "⇧ click"], "Add to selection / select a range"),
                (["⌫"], "Delete layer"),
                (["D"], "Enable / disable layer"),
                (["I", "O"], "Set layer in / out at playhead"),
                (["⌥X"], "Clear in / out"),
                (["⌥↑", "⌥↓"], "Move layer up / down"),
                (["Esc", "⇧⌘A"], "Leave field · deselect"),
                (["double-click"], "Edit text on canvas"),
                (["⌥ click"], "Select a full-frame background layer"),
                (["⌘←", "⌘→", "⌘↑", "⌘↓"], "Nudge selected layers 1 px (⇧ = 10 px)"),
                (["⇧ click", "drag"], "Canvas: add to selection · marquee select"),
                (["⇧ scale", "⇧ rotate"], "Uniform scale · 15° steps"),
                (["⌥ drag ✛"], "Move the anchor point only"),
                (["hold ⌘"], "Drag without snapping"),
            ]
        ),
        (
            "Project",
            [
                (["⌘S"], "Save now (autosave is on)"),
                (["⌘E"], "Export"),
                (["⌘,"], "Settings · canvas size · fps"),
                (["⇧⌘N"], "New scene"),
                (["⌥⌘N"], "New scene from template"),
                (["⌥⇧⌘S"], "Save scene as template"),
                (["⇧⌘I"], "Import assets"),
                (["⇧⌘H"], "Back to projects"),
                (["⌘?"], "This list"),
            ]
        ),
        (
            "AI & window",
            [
                (["⌥⌘A"], "Show / hide the floating AI panel (activity, notes, connection)"),
                (["click name"], "Rename project or scene · ↩ or click away saves · Esc cancels"),
            ]
        ),
    ]
}

extension Shortcuts {
    /// Thumbnail workspace: Figma first, Photoshop where Figma has no key.
    static let thumbnailLeft: [Group] = [
        (
            "Tools",
            [
                (["V"], "Move / select"),
                (["M"], "Marquee — select an area for generative fill"),
                (["W"], "Select subject of the selected picture (on-device)"),
                (["T"], "Text — click to place"),
                (["R", "O", "L"], "Rectangle · ellipse · line — drag to draw (⇧ = square / circle)"),
                (["⇧⌘K"], "Place image"),
                (["H", "space drag"], "Hand: pan the board"),
                (["Z", "⌥ click"], "Zoom in · out"),
                (["A", "F"], "New artboard like this one, to the right"),
                (["Esc"], "Back to Move · deselect"),
            ]
        ),
        (
            "View",
            [
                (["⇧0"], "Zoom to 100%"),
                (["⇧1"], "Zoom to fit all artboards"),
                (["⇧2"], "Zoom to the open artboard"),
                (["⌘=", "⌘−"], "Zoom in / out"),
                (["pinch", "⌘ scroll"], "Zoom at the pointer"),
                (["scroll"], "Pan"),
                (["click artboard"], "Edit that artboard (variants, covers)"),
                (["drag artboard name"], "Move the artboard on the board"),
                (["P"], "Full-screen viewer"),
            ]
        ),
    ]

    static let thumbnailRight: [Group] = [
        (
            "Layers",
            [
                (["⌘Z", "⇧⌘Z"], "Undo / redo"),
                (["⌘C", "⌘X", "⌘V"], "Copy / cut / paste layers (also between artboards)"),
                (["⌘D", "⌘J"], "Duplicate"),
                (["⌘G", "⇧⌘G"], "Group / ungroup"),
                (["⌘]", "⌘["], "Bring forward / send backward"),
                (["⌥⌘]", "⌥⌘["], "Bring to front / send to back"),
                (["⇧⌘H"], "Show / hide layer"),
                (["⇧⌘L"], "Lock / unlock layer"),
                (["←", "→", "↑", "↓"], "Nudge 1 px (⇧ = 10 px)"),
                (["⌫"], "Delete"),
                (["double-click"], "Edit text on canvas"),
                (["⇧ scale", "⇧ rotate"], "Uniform scale · 15° steps"),
            ]
        ),
        (
            "AI",
            [
                (["⌥⌘B"], "Remove background (on-device, free)"),
                (["⇧⌘F"], "Generative fill on the marquee (fal.ai key)"),
                (["⌘K"], "Generate an image from a prompt (fal.ai key)"),
                (["Esc"], "Close the prompt · clear the marquee"),
            ]
        ),
        (
            "Project",
            [
                (["⌘1", "⌘2"], "Motion / Thumbnails workspace"),
                (["⇧⌘N"], "New thumbnail page"),
                (["⇧⌘H (Motion)"], "Back to projects — in Thumbnails it hides the layer"),
                (["⌘E"], "Export thumbnails"),
                (["⌘S"], "Save now (autosave is on)"),
                (["⌥⌘A"], "Show / hide the AI panel"),
                (["⌘?"], "This list"),
            ]
        ),
    ]
}

struct ShortcutsSheet: View {
    @Binding var isPresented: Bool
    var thumbnail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Keyboard shortcuts").font(.system(size: 15, weight: .semibold)).foregroundStyle(UI.text)
                Spacer()
                Text(thumbnail ? "Thumbnails · based on Figma & Photoshop" : "Motion · based on DaVinci Resolve")
                    .font(UI.small).foregroundStyle(UI.dim)
            }
            .padding(.horizontal, 24).padding(.vertical, 18)
            Hairline()
            ScrollView {
                HStack(alignment: .top, spacing: 36) {
                    column(thumbnail ? Shortcuts.thumbnailLeft : Shortcuts.left)
                    column(thumbnail ? Shortcuts.thumbnailRight : Shortcuts.right)
                }
                .padding(24)
            }
            Hairline()
            HStack {
                Spacer()
                Button("Done") { isPresented = false }.buttonStyle(PillButtonStyle(primary: true)).keyboardShortcut(
                    .defaultAction)
            }
            .padding(16)
        }
        .frame(width: 860, height: 600).background(UI.panel)
        .themedRoot()  // a sheet is its own window: follow theme changes while it's open
    }

    private func column(_ groups: [Shortcuts.Group]) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            ForEach(groups, id: \.group) { g in
                VStack(alignment: .leading, spacing: 8) {
                    SmallCapsLabel(g.group)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                        ForEach(Array(g.items.enumerated()), id: \.offset) { _, it in
                            GridRow {
                                HStack(spacing: 4) { ForEach(it.keys, id: \.self) { Keycap(text: $0) } }
                                    .frame(width: 150, alignment: .leading)
                                Text(it.action).font(UI.font).foregroundStyle(UI.label2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct Keycap: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(UI.text)
            .padding(.horizontal, 6).frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 4).fill(UI.raised))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(UI.fieldBorder))
            .fixedSize()
    }
}
