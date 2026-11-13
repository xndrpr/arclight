import Foundation
import Testing

@testable import ArclightCore

/// Preview pages: JSON shape, old-project compatibility, theme link, store save / conflict / history / revert.
@Suite struct PreviewModelTests {
    private func sample() -> Preview {
        var a = Artboard(id: "a", name: "A")
        a.background = .value("$bg")
        a.nodes = [Node(id: "title", type: "text", props: ["text": .value("HELLO"), "size": .value(140)])]
        return Preview(id: "thumb", name: "Thumbnail", artboards: [a])
    }

    @Test func roundTripsAndDefaults() throws {
        let p = sample()
        let back = try JSONDecoder().decode(Preview.self, from: JSONEncoder().encode(p))
        #expect(back == p)
        // Minimal JSON fills in a YouTube-sized artboard at the origin and a project-linked theme.
        let min = try JSONDecoder().decode(
            Preview.self, from: Data(#"{"id":"p","artboards":[{"id":"a"}]}"#.utf8))
        #expect(min.theme == .project)
        #expect(min.artboards[0].size == [1280, 720])
        #expect(min.artboards[0].x == 0 && min.artboards[0].nodes.isEmpty)
    }

    @Test func detachedThemeEncodesAndMergesOverProject() throws {
        var p = sample()
        p.theme = .detached(["accent": "#FF0000"])
        let json = String(decoding: try JSONEncoder().encode(p.theme), as: UTF8.self)
        #expect(json.contains("detached"))
        let back = try JSONDecoder().decode(ThemeLink.self, from: Data(json.utf8))
        #expect(back == p.theme)
        let project = Project(name: "x")
        let t = project.theme(for: p)
        #expect(t["accent"] == "#FF0000")
        #expect(t["fg"] == project.theme["fg"])  // tokens the copy lacks still resolve
        #expect(project.theme(for: sample()) == project.theme)
    }

    @Test func artboardAdaptsToSceneAndBack() throws {
        var a = sample().artboards[0]
        a.size = [1080, 1920]
        let s = a.asScene(preview: "thumb", rev: 3)
        #expect(s.id == "thumb~a")
        #expect(s.size == [1080, 1920] && s.rev == 3 && s.duration > 0)
        #expect(Validator.validate(s).isEmpty)
        var edited = s
        edited.nodes.append(Node(id: "box", type: "shape", props: ["shape": .value("rect")]))
        edited.background = .value("#111111")
        a.update(from: edited)
        #expect(a.nodes.map(\.id) == ["title", "box"])
        #expect(a.background == .value("#111111"))
    }

    @Test func oldProjectJSONHasNoPreviewKeys() throws {
        let p = Project(name: "old")
        let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(!json.contains("previews") && !json.contains("workspace"))
        let back = try JSONDecoder().decode(Project.self, from: Data(#"{"name":"old","scenes":["s"]}"#.utf8))
        #expect(back.previews.isEmpty && back.workspace == nil)
    }

    @Test func storeSavesReloadsAndOrdersPreviews() throws {
        let tp = try TempProject("preview-store")
        defer { tp.remove() }
        let saved = try tp.store.save(preview: sample())
        #expect(saved.rev == 1)
        #expect(tp.store.project.previews == ["thumb"])
        let again = try ProjectStore(url: tp.url)
        #expect(again.previews["thumb"]?.artboards.first?.nodes.first?.id == "title")
        #expect(again.orderedPreviews.map(\.id) == ["thumb"])
        // A preview file dropped in by hand is picked up and ordered after the known ones.
        var other = sample(); other.id = "aaa"
        try JSONEncoder().encode(other).write(to: tp.url.appendingPathComponent("previews/aaa.json"))
        try again.reload()
        #expect(again.project.previews == ["thumb", "aaa"])
    }

    @Test func staleRevIsRefusedAndHistoryReverts() throws {
        let tp = try TempProject("preview-history")
        defer { tp.remove() }
        var p = try tp.store.save(preview: sample())
        p.artboards[0].nodes[0].props["text"] = .value("SECOND")
        p = try tp.store.save(preview: p, expectedRev: 1, summary: "retitle")
        #expect(p.rev == 2)
        #expect(throws: (any Error).self) { try tp.store.save(preview: p, expectedRev: 1) }
        let hist = tp.store.previewHistory("thumb")
        #expect(hist.map(\.rev).contains(1) && hist.map(\.rev).contains(2))
        #expect(hist.last?.changed == ["a/title"])
        let r = try tp.store.revertPreview("thumb", to: 1)
        #expect(r.rev == 3)
        #expect(r.artboards[0].nodes[0].props["text"] == .value("HELLO"))
        // Preview history lives apart from scene history.
        #expect(tp.store.history("thumb").isEmpty)
    }

    @Test func artboardSceneSavesIntoItsPreview() throws {
        let tp = try TempProject("preview-artboard")
        defer { tp.remove() }
        let p = try tp.store.save(preview: sample())
        var s = p.artboards[0].asScene(preview: p.id, rev: p.rev)
        s.nodes[0].props["size"] = .value(200)
        let out = try tp.store.save(artboardScene: s, preview: "thumb", artboard: "a", expectedRev: p.rev)
        #expect(out.artboards[0].nodes[0].props["size"] == .value(200))
        #expect(tp.store.scenes.isEmpty)  // never becomes a motion scene
    }

    @Test func duplicateArtboardIdsAreRejected() throws {
        let tp = try TempProject("preview-dupes")
        defer { tp.remove() }
        var p = sample()
        p.artboards.append(Artboard(id: "a"))
        #expect(throws: (any Error).self) { try tp.store.save(preview: p) }
        #expect(p.uniqueArtboardId("a") == "a-2")
        #expect(p.nextArtboardOrigin().0 == 1280 + 120)
    }

    @Test func deleteRemovesFileAndOrder() throws {
        let tp = try TempProject("preview-delete")
        defer { tp.remove() }
        try tp.store.save(preview: sample())
        try tp.store.deletePreview("thumb")
        #expect(tp.store.previews.isEmpty && tp.store.project.previews.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tp.url.appendingPathComponent("previews/thumb.json").path))
    }
}
