import AppKit
import Foundation
import SwiftUI
import Testing

@testable import ArclightCore
@testable import ArclightEditor

/// Window chrome (title-bar double-click, no background window drags), app theme switching, inspector field drafts
/// and scrubbing (live text, Duration = END, one undo step).
@Suite(.serialized) struct ChromeTests {
    // MARK: Window chrome

    @Test func titlebarDoubleClickFollowsSystemSetting() {
        #expect(TitlebarDoubleClick.action(actionOnDoubleClick: nil, miniaturizeOnDoubleClick: nil) == .zoom)
        #expect(TitlebarDoubleClick.action(actionOnDoubleClick: "Maximize", miniaturizeOnDoubleClick: nil) == .zoom)
        #expect(TitlebarDoubleClick.action(actionOnDoubleClick: "Fill", miniaturizeOnDoubleClick: nil) == .zoom)
        #expect(TitlebarDoubleClick.action(actionOnDoubleClick: "Minimize", miniaturizeOnDoubleClick: nil) == .minimize)
        #expect(TitlebarDoubleClick.action(actionOnDoubleClick: "None", miniaturizeOnDoubleClick: true) == .none)
        // older macOS
        #expect(TitlebarDoubleClick.action(actionOnDoubleClick: nil, miniaturizeOnDoubleClick: true) == .minimize)
    }

    @Test @MainActor func appWindowsNeverMoveFromTheirContent() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: true)
        w.isMovableByWindowBackground = true
        AppWindows.configure(w, background: .panel, content: Text("x"))
        #expect(!w.isMovableByWindowBackground)
        #expect(w.titlebarAppearsTransparent)
        #expect(w.contentView?.mouseDownCanMoveWindow == false)  // a moving tap-to-click stays a click
        #expect((w.contentView as? ThemedWindowContent)?.windowBackground == .panel)
        #expect(WindowDragArea.DragView().mouseDownCanMoveWindow == false)  // drags itself via performDrag
    }

    // MARK: App theme

    @Test @MainActor func applyThemeUpdatesEverything() {
        let d = Pref.store
        let saved = d.string(forKey: Pref.theme)
        defer {
            if let saved { d.set(saved, forKey: Pref.theme) } else { d.removeObject(forKey: Pref.theme) }
            AppTheme.resetForTesting()
        }
        AppTheme.resetForTesting()
        AppTheme.apply(.dark)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered,
            defer: true)
        AppWindows.configure(w, content: Text("x"))
        #expect(w.appearance?.name == .darkAqua)

        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: .appThemeChanged, object: nil, queue: nil) { _ in
            posted += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        AppTheme.apply(.gruvboxLight)
        #expect(d.string(forKey: Pref.theme) == AppTheme.gruvboxLight.rawValue)  // saved: @AppStorage roots re-render
        #expect(AppTheme.current == .gruvboxLight && !UI.isDark)  // UI.* read the new palette
        #expect(posted == 1)  // long-lived AppKit / Metal objects
        AppTheme.apply(.gruvboxLight)
        #expect(posted == 1)  // no-op when unchanged

        // A change written straight to the defaults (`defaults write`, another process) is picked up too.
        d.set(AppTheme.nord.rawValue, forKey: Pref.theme)
        AppTheme.syncFromDefaults()
        #expect(AppTheme.current == .nord && UI.isDark && posted == 2)
    }

    @Test func windowBackgroundRoles() {
        let p = AppTheme.light.palette
        #expect(WindowBackground.bg.color(p) == p.bg && WindowBackground.panel.color(p) == p.panel)
    }

    // MARK: Field drafts

    @Test func draftFollowsModelUntilTyped() {
        var f = FieldDraft("5")
        f.sync("5.1", focused: false)
        #expect(f.text == "5.1")
        // Clicked into the field, then scrubbed the label: focused but nothing typed → keeps following.
        f.sync("5.2", focused: true)
        #expect(f.text == "5.2" && !f.isDirty)
        #expect(f.finish("5.2") == nil)  // leaving without typing commits nothing
        // Typing: an outside change doesn't clobber it while focused; leaving commits what was typed.
        f.edit("7")
        f.sync("5.3", focused: true)
        #expect(f.text == "7")
        #expect(f.finish("5.3") == "7")
        #expect(f.text == "5.3")  // shows the model until the commit comes back
        // Unfocused: the model always wins.
        f.edit("9")
        f.sync("6", focused: false)
        #expect(f.text == "6" && !f.isDirty)
        // Typing the value it already has commits nothing.
        f.edit("6")
        #expect(f.finish("6") == nil)
    }

    // MARK: Scrubbing

    func makeScrubDoc() throws -> (EditorDocument, TempProject) {
        var s = ArclightCore.Scene(id: "s", duration: 4)
        s.nodes = [
            Node(
                id: "a", type: "shape",
                props: [
                    "x": .keys([Keyframe(t: 0, v: 0), Keyframe(t: 3, v: 100)]),
                    "anchor": .value([0, 0]),
                ])
        ]
        return try makeDoc(scene: s)
    }

    @Test(.requiresMetal) func durationScrubMovesEndLiveAsOneUndo() throws {
        let (doc, project) = try makeScrubDoc()
        defer { project.remove() }
        let f = Schema.sceneFields.first { $0.name == "duration" }!
        let slot = doc.slot(.scene, "duration", field: f)
        doc.scrub(slot, 4, .began)
        for v in stride(from: 4.0, through: 2.0, by: -0.1) {
            doc.scrub(doc.slot(.scene, "duration", field: f), v, .changed)
            #expect(abs(doc.scene.duration - (v * doc.fps).rounded() / doc.fps) < 1e-9)  // END follows every step
        }
        doc.scrub(slot, 2, .ended)
        // Below the last keyframe (3 s): stays where it was dragged, like dragging END (no snap back).
        #expect(abs(doc.scene.duration - 2) < 1e-9)
        #expect(doc.slot(.scene, "duration", field: f).shown == .number(doc.scene.duration))  // the field shows it
        doc.undo()
        #expect(doc.scene.duration == 4)  // the whole drag is one step
    }

    @Test(.requiresMetal) func vectorComponentScrub() throws {
        let (doc, project) = try makeScrubDoc()
        defer { project.remove() }
        let f = Field("anchor", .vector(labels: ["x", "y"], unit: "px"), "")
        let s = doc.slot(.node("a"), "anchor", field: f)
        #expect(vectorScrubStep(s, [0, 0]) == 1)
        #expect(
            vectorScrubStep(
                doc.slot(.node("a"), "anchor", field: Field("trim", .vector(labels: ["s", "e"]), "")), [0, 1]) == 0.01)
        let scrub = try #require(
            vectorScrub(doc, s) { i, v in
                var a = doc.slot(.node("a"), "anchor", field: f).shown?.doubles ?? [0, 0]
                a[i] = v
                doc.write(s, .array(a.map { .number($0) }))
            })
        scrub(1, 0, .began)
        scrub(1, 10, .changed)
        scrub(1, 25, .changed)
        scrub(1, 25, .ended)
        #expect(doc.scene.node("a")?.props["anchor"] == .value([0, 25]))
        doc.undo()
        #expect(doc.scene.node("a")?.props["anchor"] == .value([0, 0]))
    }
}
