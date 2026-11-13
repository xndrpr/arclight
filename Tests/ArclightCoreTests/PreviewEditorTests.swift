import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightEditor

/// The editor's Preview workspace: artboards edited through the same working-copy path as scenes.
@Suite(.serialized, .requiresMetal) struct PreviewEditorTests {
    private static func page(_ id: String = "thumb") -> ArclightCore.Preview {
        var a = Artboard(id: "a", name: "A")
        a.nodes = [Node(id: "title", type: "text", props: ["text": .value("HELLO"), "size": .value(140)])]
        return ArclightCore.Preview(id: id, name: "Thumb", artboards: [a])
    }

    /// A project with one motion scene and one preview page.
    private func both() throws -> TempProject {
        let tp = try TempProject("pv-doc", scenes: [ArclightCore.Scene(id: "s", duration: 2)])
        try tp.store.save(preview: Self.page())
        return tp
    }

    @Test func previewOnlyProjectOpensOnPreviewWithoutMakingAScene() throws {
        let tp = try TempProject("pv-only")
        defer { tp.remove() }
        try tp.store.save(preview: Self.page())
        let doc = try EditorDocument(url: tp.url)
        #expect(doc.workspace == .preview)
        #expect(doc.target == .artboard(preview: "thumb", artboard: "a"))
        #expect(doc.scene.node("title") != nil)
        #expect(doc.store.scenes.isEmpty)  // no "scene-1" was forced on it
        // Motion is empty until the user asks for a scene.
        doc.setWorkspace(.motion)
        #expect(doc.isEmptyWorkspace)
        doc.saveNow()  // the placeholder is never written
        #expect(try ProjectStore(url: tp.url).scenes.isEmpty)
        doc.newScene()
        #expect(doc.target == .scene("scene-1") && doc.workspace == .motion)
    }

    @Test func projectStartingInPreviewGetsAStarterPage() throws {
        let tp = try TempProject("pv-start")
        defer { tp.remove() }
        var p = tp.store.project; p.workspace = "preview"
        try tp.store.update(project: p)
        let doc = try EditorDocument(url: tp.url)
        #expect(doc.previews.map(\.id) == ["preview-1"])
        #expect(doc.canvasSize == CGSize(width: 1280, height: 720))
    }

    @Test func editingAnArtboardSavesIntoItsPageWithUndo() throws {
        let tp = try both()
        defer { tp.remove() }
        let doc = try EditorDocument(url: tp.url)
        #expect(doc.workspace == .motion)
        doc.setWorkspace(.preview)
        #expect(try ProjectStore(url: tp.url).project.workspace == "preview")  // remembered
        doc.set("title", "text", "NEW WORDS")
        doc.saveNow()
        let disk = try ProjectStore(url: tp.url)
        #expect(disk.previews["thumb"]?.artboards[0].nodes[0].props["text"] == .value("NEW WORDS"))
        #expect(disk.previews["thumb"]?.rev == 2)
        #expect(disk.scenes["s"]?.nodes.isEmpty == true)  // the motion scene is untouched
        doc.undo(); doc.saveNow()
        #expect(try ProjectStore(url: tp.url).previews["thumb"]?.artboards[0].nodes[0].props["text"] == .value("HELLO"))
        // History lists the page's revisions and restores this artboard from one.
        #expect(doc.history().map(\.rev).contains(2))
        doc.restore(rev: 2)
        #expect(doc.scene.node("title")?.props["text"] == .value("NEW WORDS"))
    }

    @Test func liveReloadFollowsAnAgentEditingThePage() throws {
        let tp = try both()
        defer { tp.remove() }
        let doc = try EditorDocument(url: tp.url)
        doc.setWorkspace(.preview)
        let other = try ProjectStore(url: tp.url)
        var p = try other.preview("thumb")
        p.artboards[0].nodes[0].props["text"] = .value("FROM THE AI")
        Thread.sleep(forTimeInterval: 1.1)  // file mtime resolution
        try other.save(preview: p, summary: "mcp")
        doc.poll()
        #expect(doc.scene.node("title")?.props["text"] == .value("FROM THE AI"))
        doc.undo()
        #expect(doc.scene.node("title")?.props["text"] == .value("HELLO"))
    }

    @Test func artboardPageOpsVariantsAndDelete() throws {
        let tp = try both()
        defer { tp.remove() }
        let doc = try EditorDocument(url: tp.url)
        doc.setWorkspace(.preview)
        doc.duplicateArtboard("a", in: "thumb")
        #expect(doc.openPreview?.artboards.map(\.name) == ["A", "B"])
        #expect(doc.target == .artboard(preview: "thumb", artboard: "b"))
        #expect(doc.scene.node("title") != nil)
        let shorts = try #require(ArtboardPresets.all.first { $0.id == "shorts" })
        doc.addArtboard(preset: shorts)
        #expect(doc.canvasSize == CGSize(width: 1080, height: 1920))
        doc.deleteArtboard("b", in: "thumb")
        #expect(doc.openPreview?.artboards.map(\.id) == ["a", "shorts"])
        doc.newPreview()
        #expect(doc.previews.count == 2)
        doc.deletePreview(doc.target.previewId ?? "")
        #expect(doc.previews.map(\.id) == ["thumb"] && doc.target.previewId == "thumb")
    }

    @Test func detachedThemeEditsStayInThePreview() throws {
        let tp = try both()
        defer { tp.remove() }
        let doc = try EditorDocument(url: tp.url)
        doc.setWorkspace(.preview)
        let projectFG = doc.store.project.theme["fg"]
        doc.detachTheme()
        #expect(doc.themeIsDetached)
        doc.setThemeToken("fg", "#FF0044")
        #expect(doc.project.theme["fg"] == "#FF0044")  // the open preview renders with it
        let disk = try ProjectStore(url: tp.url)
        #expect(disk.project.theme["fg"] == projectFG)  // the project theme is untouched
        #expect(disk.project.theme(for: try disk.preview("thumb"))["fg"] == "#FF0044")
        doc.setWorkspace(.motion)
        #expect(doc.project.theme["fg"] == projectFG)
        doc.setWorkspace(.preview)
        doc.relinkTheme()
        #expect(doc.project.theme["fg"] == projectFG)
    }

    @Test func revealOpensArtboardsFromTheActivityFeed() throws {
        let tp = try both()
        defer { tp.remove() }
        let doc = try EditorDocument(url: tp.url)
        doc.reveal(scene: Artboard.sceneId(preview: "thumb", artboard: "a"), layer: "title")
        #expect(doc.workspace == .preview && doc.selection == "title")
        doc.reveal(scene: "s", layer: nil)
        #expect(doc.workspace == .motion && doc.target == .scene("s"))
    }
}
