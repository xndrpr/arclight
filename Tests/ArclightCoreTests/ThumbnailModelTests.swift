import Foundation
import Testing

@testable import ArclightCore

/// Thumbnail pages: JSON shape, old-project compatibility, theme link, store save / conflict / history / revert.
@Suite struct ThumbnailModelTests {
    private func sample() -> Thumbnail {
        var a = Artboard(id: "a", name: "A")
        a.background = .value("$bg")
        a.nodes = [Node(id: "title", type: "text", props: ["text": .value("HELLO"), "size": .value(140)])]
        return Thumbnail(id: "thumb", name: "Thumbnail", artboards: [a])
    }

    @Test func roundTripsAndDefaults() throws {
        let p = sample()
        let back = try JSONDecoder().decode(Thumbnail.self, from: JSONEncoder().encode(p))
        #expect(back == p)
        // Minimal JSON fills in a YouTube-sized artboard at the origin and a project-linked theme.
        let min = try JSONDecoder().decode(
            Thumbnail.self, from: Data(#"{"id":"p","artboards":[{"id":"a"}]}"#.utf8))
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
        let s = a.asScene(thumbnail: "thumb", rev: 3)
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

    @Test func oldProjectJSONHasNoThumbnailKeys() throws {
        let p = Project(name: "old")
        let json = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        #expect(!json.contains("thumbnails") && !json.contains("workspace"))
        let back = try JSONDecoder().decode(Project.self, from: Data(#"{"name":"old","scenes":["s"]}"#.utf8))
        #expect(back.thumbnails.isEmpty && back.workspace == nil)
    }

    @Test func storeSavesReloadsAndOrdersThumbnails() throws {
        let tp = try TempProject("thumbnail-store")
        defer { tp.remove() }
        let saved = try tp.store.save(thumbnail: sample())
        #expect(saved.rev == 1)
        #expect(tp.store.project.thumbnails == ["thumb"])
        let again = try ProjectStore(url: tp.url)
        #expect(again.thumbnails["thumb"]?.artboards.first?.nodes.first?.id == "title")
        #expect(again.orderedThumbnails.map(\.id) == ["thumb"])
        // A thumbnail file dropped in by hand is picked up and ordered after the known ones.
        var other = sample(); other.id = "aaa"
        try JSONEncoder().encode(other).write(to: tp.url.appendingPathComponent("thumbnails/aaa.json"))
        try again.reload()
        #expect(again.project.thumbnails == ["thumb", "aaa"])
    }

    /// Before the rename, thumbnails were "previews": the previews/ folder, the "previews" key, workspace "preview".
    @Test func projectFromBeforeTheRenameStillOpens() throws {
        let tp = try TempProject("thumbnail-legacy")
        defer { tp.remove() }
        try tp.store.save(thumbnail: sample())
        let fm = FileManager.default
        try fm.moveItem(at: tp.url.appendingPathComponent("thumbnails"), to: tp.url.appendingPathComponent("previews"))
        let pj = tp.url.appendingPathComponent("project.json")
        var json = try String(contentsOf: pj, encoding: .utf8)
        json = json.replacingOccurrences(of: "\"thumbnails\"", with: "\"previews\"")
        json = json.replacingOccurrences(of: "\"workspace\" : \"thumbnail\"", with: "\"workspace\" : \"preview\"")
        try json.write(to: pj, atomically: true, encoding: .utf8)

        let old = try ProjectStore(url: tp.url)
        #expect(old.project.thumbnails == ["thumb"])
        #expect(old.thumbnails["thumb"] != nil)
        #expect(fm.fileExists(atPath: tp.url.appendingPathComponent("thumbnails/thumb.json").path))
        #expect(!fm.fileExists(atPath: tp.url.appendingPathComponent("previews").path))
        let p = try JSONDecoder().decode(Project.self, from: Data(#"{"workspace":"preview","previews":["x"]}"#.utf8))
        #expect(p.workspace == "thumbnail" && p.thumbnails == ["x"])
    }

    @Test func staleRevIsRefusedAndHistoryReverts() throws {
        let tp = try TempProject("thumbnail-history")
        defer { tp.remove() }
        var p = try tp.store.save(thumbnail: sample())
        p.artboards[0].nodes[0].props["text"] = .value("SECOND")
        p = try tp.store.save(thumbnail: p, expectedRev: 1, summary: "retitle")
        #expect(p.rev == 2)
        #expect(throws: (any Error).self) { try tp.store.save(thumbnail: p, expectedRev: 1) }
        let hist = tp.store.thumbnailHistory("thumb")
        #expect(hist.map(\.rev).contains(1) && hist.map(\.rev).contains(2))
        #expect(hist.last?.changed == ["a/title"])
        let r = try tp.store.revertThumbnail("thumb", to: 1)
        #expect(r.rev == 3)
        #expect(r.artboards[0].nodes[0].props["text"] == .value("HELLO"))
        // Thumbnail history lives apart from scene history.
        #expect(tp.store.history("thumb").isEmpty)
    }

    @Test func artboardSceneSavesIntoItsThumbnail() throws {
        let tp = try TempProject("thumbnail-artboard")
        defer { tp.remove() }
        let p = try tp.store.save(thumbnail: sample())
        var s = p.artboards[0].asScene(thumbnail: p.id, rev: p.rev)
        s.nodes[0].props["size"] = .value(200)
        let out = try tp.store.save(artboardScene: s, thumbnail: "thumb", artboard: "a", expectedRev: p.rev)
        #expect(out.artboards[0].nodes[0].props["size"] == .value(200))
        #expect(tp.store.scenes.isEmpty)  // never becomes a motion scene
    }

    @Test func duplicateArtboardIdsAreRejected() throws {
        let tp = try TempProject("thumbnail-dupes")
        defer { tp.remove() }
        var p = sample()
        p.artboards.append(Artboard(id: "a"))
        #expect(throws: (any Error).self) { try tp.store.save(thumbnail: p) }
        #expect(p.uniqueArtboardId("a") == "a-2")
        #expect(p.nextArtboardOrigin().0 == 1280 + 120)
    }

    @Test func deleteRemovesFileAndOrder() throws {
        let tp = try TempProject("thumbnail-delete")
        defer { tp.remove() }
        try tp.store.save(thumbnail: sample())
        try tp.store.deleteThumbnail("thumb")
        #expect(tp.store.thumbnails.isEmpty && tp.store.project.thumbnails.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: tp.url.appendingPathComponent("thumbnails/thumb.json").path))
    }

    @Test func importingASymlinkCopiesTheFileItPointsTo() throws {
        let tp = try TempProject("symlink-import")
        defer { tp.remove() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("real"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("png".utf8).write(to: dir.appendingPathComponent("real/pic.png"))
        try FileManager.default.createSymbolicLink(
            atPath: dir.appendingPathComponent("pic.png").path, withDestinationPath: "real/pic.png")
        let name = try tp.store.importAsset(from: dir.appendingPathComponent("pic.png"))
        let copied = tp.store.assetsURL.appendingPathComponent(name)
        let attrs = try FileManager.default.attributesOfItem(atPath: copied.path)
        #expect(attrs[.type] as? FileAttributeType == .typeRegular)
        #expect(try Data(contentsOf: copied) == Data("png".utf8))
    }
}
