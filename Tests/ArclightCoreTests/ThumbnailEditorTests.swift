import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightEditor

/// The editor's Thumbnail workspace: artboards edited through the same working-copy path as scenes.
@Suite(.serialized, .requiresMetal) struct ThumbnailEditorTests {
    private static func page(_ id: String = "thumb") -> ArclightCore.Thumbnail {
        var a = Artboard(id: "a", name: "A")
        a.nodes = [Node(id: "title", type: "text", props: ["text": .value("HELLO"), "size": .value(140)])]
        return ArclightCore.Thumbnail(id: id, name: "Thumb", artboards: [a])
    }

    /// A project with one motion scene and one thumbnail page.
    private func both() throws -> TempProject {
        let tp = try TempProject("pv-doc", scenes: [ArclightCore.Scene(id: "s", duration: 2)])
        try tp.store.save(thumbnail: Self.page())
        return tp
    }

    @Test func thumbnailOnlyProjectOpensOnThumbnailWithoutMakingAScene() throws {
        let tp = try TempProject("pv-only")
        defer { tp.remove() }
        try tp.store.save(thumbnail: Self.page())
        let doc = try EditorDocument(url: tp.url)
        #expect(doc.workspace == .thumbnail)
        #expect(doc.target == .artboard(thumbnail: "thumb", artboard: "a"))
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

    @Test func projectStartingInThumbnailGetsAStarterPage() throws {
        let tp = try TempProject("pv-start")
        defer { tp.remove() }
        var p = tp.store.project; p.workspace = "thumbnail"
        try tp.store.update(project: p)
        let doc = try EditorDocument(url: tp.url)
        #expect(doc.thumbnails.map(\.id) == ["thumbnail-1"])
        #expect(doc.canvasSize == CGSize(width: 1280, height: 720))
    }

    @Test func editingAnArtboardSavesIntoItsPageWithUndo() throws {
        let tp = try both()
        defer { tp.remove() }
        let doc = try EditorDocument(url: tp.url)
        #expect(doc.workspace == .motion)
        doc.setWorkspace(.thumbnail)
        #expect(try ProjectStore(url: tp.url).project.workspace == "thumbnail")  // remembered
        doc.set("title", "text", "NEW WORDS")
        doc.saveNow()
        let disk = try ProjectStore(url: tp.url)
        #expect(disk.thumbnails["thumb"]?.artboards[0].nodes[0].props["text"] == .value("NEW WORDS"))
        #expect(disk.thumbnails["thumb"]?.rev == 2)
        #expect(disk.scenes["s"]?.nodes.isEmpty == true)  // the motion scene is untouched
        doc.undo(); doc.saveNow()
        #expect(
            try ProjectStore(url: tp.url).thumbnails["thumb"]?.artboards[0].nodes[0].props["text"] == .value("HELLO"))
        // History lists the page's revisions and restores this artboard from one.
        #expect(doc.history().map(\.rev).contains(2))
        doc.restore(rev: 2)
        #expect(doc.scene.node("title")?.props["text"] == .value("NEW WORDS"))
    }

    @Test func liveReloadFollowsAnAgentEditingThePage() throws {
        let tp = try both()
        defer { tp.remove() }
        let doc = try EditorDocument(url: tp.url)
        doc.setWorkspace(.thumbnail)
        let other = try ProjectStore(url: tp.url)
        var p = try other.thumbnail("thumb")
        p.artboards[0].nodes[0].props["text"] = .value("FROM THE AI")
        Thread.sleep(forTimeInterval: 1.1)  // file mtime resolution
        try other.save(thumbnail: p, summary: "mcp")
        doc.poll()
        #expect(doc.scene.node("title")?.props["text"] == .value("FROM THE AI"))
        doc.undo()
        #expect(doc.scene.node("title")?.props["text"] == .value("HELLO"))
    }

    @Test func artboardPageOpsVariantsAndDelete() throws {
        let tp = try both()
        defer { tp.remove() }
        let doc = try EditorDocument(url: tp.url)
        doc.setWorkspace(.thumbnail)
        doc.duplicateArtboard("a", in: "thumb")
        #expect(doc.openThumbnail?.artboards.map(\.name) == ["A", "B"])
        #expect(doc.target == .artboard(thumbnail: "thumb", artboard: "b"))
        #expect(doc.scene.node("title") != nil)
        let shorts = try #require(ArtboardPresets.all.first { $0.id == "shorts" })
        doc.addArtboard(preset: shorts)
        #expect(doc.canvasSize == CGSize(width: 1080, height: 1920))
        doc.deleteArtboard("b", in: "thumb")
        #expect(doc.openThumbnail?.artboards.map(\.id) == ["a", "shorts"])
        doc.newThumbnail()
        #expect(doc.thumbnails.count == 2)
        doc.deleteThumbnail(doc.target.thumbnailId ?? "")
        #expect(doc.thumbnails.map(\.id) == ["thumb"] && doc.target.thumbnailId == "thumb")
    }

    @Test func detachedThemeEditsStayInTheThumbnail() throws {
        let tp = try both()
        defer { tp.remove() }
        let doc = try EditorDocument(url: tp.url)
        doc.setWorkspace(.thumbnail)
        let projectFG = doc.store.project.theme["fg"]
        doc.detachTheme()
        #expect(doc.themeIsDetached)
        doc.setThemeToken("fg", "#FF0044")
        #expect(doc.project.theme["fg"] == "#FF0044")  // the open thumbnail renders with it
        let disk = try ProjectStore(url: tp.url)
        #expect(disk.project.theme["fg"] == projectFG)  // the project theme is untouched
        #expect(disk.project.theme(for: try disk.thumbnail("thumb"))["fg"] == "#FF0044")
        doc.setWorkspace(.motion)
        #expect(doc.project.theme["fg"] == projectFG)
        doc.setWorkspace(.thumbnail)
        doc.relinkTheme()
        #expect(doc.project.theme["fg"] == projectFG)
    }

    @Test func revealOpensArtboardsFromTheActivityFeed() throws {
        let tp = try both()
        defer { tp.remove() }
        let doc = try EditorDocument(url: tp.url)
        doc.reveal(scene: Artboard.sceneId(thumbnail: "thumb", artboard: "a"), layer: "title")
        #expect(doc.workspace == .thumbnail && doc.selection == "title")
        doc.reveal(scene: "s", layer: nil)
        #expect(doc.workspace == .motion && doc.target == .scene("s"))
    }
}
