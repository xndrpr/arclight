import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightEditor

/// Editor-side design system: inserting templates, the save-as-template picker, asset import, new projects.
@Suite(.serialized) struct LibraryUITests {
    func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    // MARK: Insert template into scene

    @Test func insertPrefixesIdsAndRemapsParentsAndExpressions() throws {
        let t = try #require(Templates.get("stat-crowd", project: nil))
        let src = try Templates.instantiate(t, params: [:], sceneId: "x", canvas: (1920, 1080))
        var target = ArclightCore.Scene(id: "s", duration: 2)
        target.nodes = [Node(id: "stat-crowd-crowd", type: "shape")]  // clash: must be made unique
        let r = LibraryModel.insert(src, into: target, prefix: "stat-crowd")
        #expect(r.scene.nodes.count == 1 + src.nodes.count)
        #expect(Set(r.scene.nodes.map(\.id)).count == r.scene.nodes.count)
        #expect(r.ids.allSatisfy { $0.hasPrefix("stat-crowd-") })
        #expect(r.ids.contains("stat-crowd-crowd-2"))
        // Expression references follow the renamed crowd.
        let counter = try #require(r.scene.node("stat-crowd-counter"))
        guard case .expr(let e)? = counter.props["value"] else {
            Issue.record("counter value should be an expression"); return
        }
        #expect(e.contains("'stat-crowd-crowd-2'") && !e.contains("'crowd'"))
        // Nested instance expressions too.
        let crowd = try #require(r.scene.node("stat-crowd-crowd-2"))
        // instance uses pick(), no id
        #expect(crowd.props["instance"]?.json.compactString.contains("stat-crowd-crowd-2") == false)
        // Camera/fog/post merged into a scene that had none; duration grows.
        #expect(r.scene.camera != nil && r.scene.post != nil && r.scene.fog != nil)
        #expect(r.scene.duration == src.duration)
    }

    @Test func insertKeepsExistingCameraAndPostAndParents() throws {
        let t = try #require(Templates.get("lower-third", project: nil))
        let src = try Templates.instantiate(t, params: [:], sceneId: "x", canvas: (1920, 1080))
        var target = ArclightCore.Scene(id: "s", duration: 9)
        target.camera = .value(["fov": 50])
        target.post = .value(["grain": 0.1])
        var withCam = src
        withCam.camera = .value(["fov": 20]); withCam.post = .value(["grain": 0.5])
        let r = LibraryModel.insert(withCam, into: target, prefix: "lt")
        #expect(r.scene.camera == .value(["fov": 50]))
        #expect(r.scene.post == .value(["grain": 0.1]))
        #expect(r.scene.duration == 9)
        #expect(r.scene.node("lt-name")?.parent == "lt-lt")
        #expect(r.scene.node("lt-lt")?.parent == nil)
    }

    // MARK: Param picker → Template.make

    @Test func pickerCandidatesAndTemplateMapping() throws {
        var s = ArclightCore.Scene(id: "brand", duration: 4)
        s.background = .value("$bg")
        s.nodes = [
            Node(
                id: "title", type: "text",
                props: ["text": .value("Hello"), "color": .value("$fg"), "size": .value(120)]),
            Node(
                id: "num", type: "text",
                props: ["text": .value("{v}%"), "value": .keys([Keyframe(t: 0, v: 0), Keyframe(t: 1.5, v: 72)])]),
            Node(id: "crowd", type: "repeater", props: ["items": .value([["symbol": "basic/person", "height": 100]])]),
        ]
        let cands = LibraryModel.candidates(s)
        let ids = cands.map(\.id)
        #expect(
            ids.contains("title/text") && ids.contains("title/color") && ids.contains("num/value.k.1.1")
                && ids.contains("crowd/items.0.symbol"))
        #expect(ids.contains("scene/background"))
        let pick = cands.filter {
            ["title/text", "num/value.k.1.1", "crowd/items.0.symbol", "scene/background"].contains($0.id)
        }
        let t = try LibraryModel.makeTemplate(
            from: s, id: "brand-stat", name: "Brand stat", description: "d", category: "Numbers", picks: pick)
        #expect(t.category == "Numbers")
        #expect(t.params.map(\.name) == pick.map(\.paramName))
        #expect(Set(t.params.map(\.name)) == ["title_text", "num_value", "crowd_symbol", "background"])
        #expect(t.params.first { $0.name == "num_value" }?.default == .number(72))
        #expect(t.params.first { $0.name == "crowd_symbol" }?.kind == "symbol")
        // Round trip: defaults reproduce the scene, new values land in the right places.
        let same = try Templates.instantiate(t, params: [:], sceneId: "brand", canvas: (1920, 1080))
        #expect(same.nodes == s.nodes)
        #expect(same.background == s.background)
        let other = try Templates.instantiate(
            t, params: ["title_text": "Bye", "num_value": 10, "crowd_symbol": "chess/pawn", "background": "#FF0000"],
            sceneId: "b2", canvas: (1920, 1080))
        #expect(other.node("title")?.props["text"] == .value("Bye"))
        #expect(other.node("num")?.props["value"] == .keys([Keyframe(t: 0, v: 0), Keyframe(t: 1.5, v: 10)]))
        #expect(other.node("crowd")?.props["items"] == .value([["symbol": "chess/pawn", "height": 100]]))
        #expect(other.background == .value("#FF0000"))
    }

    // MARK: Assets

    @Test func assetClassificationByExtension() {
        func k(_ n: String, _ c: String? = nil) -> LibraryModel.AssetKind? {
            LibraryModel.AssetKind.classify(URL(fileURLWithPath: "/x/" + n), contents: c.map { Data($0.utf8) })
        }
        #expect(k("a.PNG") == .image && k("b.jpeg") == .image && k("c.heic") == .image)
        #expect(k("v.wav") == .audio && k("v.M4A") == .audio && k("v.mp3") == .audio)
        #expect(k("f.otf") == .font && k("f.ttf") == .font)
        #expect(k("pack.json") == .symbols)
        #expect(k("pack.json", #"{"pack":"x","symbols":[]}"#) == .symbols)
        #expect(k("t.json", #"{"id":"t","name":"T","params":[],"scene":{"duration":1,"nodes":[]}}"#) == .template)
        #expect(k("notes.txt") == nil && k("movie.mov") == nil)
        #expect(LibraryModel.AssetKind.font.folder == "fonts" && LibraryModel.AssetKind.audio.folder == "assets")
    }

    @Test func importCopiesIntoTheRightFolder() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = try LibraryModel.createProject(in: dir, name: "Imp", size: (1920, 1080), fps: 30, template: nil)
        let src = dir.appendingPathComponent("brand.json")
        try Data(#"{"pack":"brand","symbols":[{"id":"logo","path":"M-20 0 L20 0 L0 -40 Z"}]}"#.utf8).write(to: src)
        let png = dir.appendingPathComponent("pic.png")
        try Data([0x89, 0x50]).write(to: png)
        #expect(try LibraryModel.importFile(src, into: proj).0 == .symbols)
        #expect(try LibraryModel.importFile(png, into: proj).0 == .image)
        #expect(FileManager.default.fileExists(atPath: proj.appendingPathComponent("symbols/brand.json").path))
        #expect(LibraryModel.files(.image, in: proj).map(\.lastPathComponent) == ["pic.png"])
        #expect(Symbols.all(project: proj).contains { $0.id == "brand/logo" })
        #expect(throws: (any Error).self) {
            try LibraryModel.importFile(dir.appendingPathComponent("x.txt"), into: proj)
        }
    }

    // MARK: New project

    @Test func newProjectFromTemplate() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let t = try #require(Templates.get("spotlight-cascade", project: nil))
        let url = try LibraryModel.createProject(
            in: dir.appendingPathComponent("nested"), name: "Launch", size: (1080, 1920), fps: 25, template: t)
        #expect(url.lastPathComponent == "Launch.arclight")
        let store = try ProjectStore(url: url)
        #expect(store.project.name == "Launch")
        #expect(store.project.size == [1080, 1920] && store.project.fps == 25)
        #expect(store.orderedScenes.count == 1)
        let s = try #require(store.orderedScenes.first)
        #expect(s.id == "spotlight-cascade")
        #expect(
            s.nodes.count == (try Templates.instantiate(t, params: [:], sceneId: "x", canvas: (1080, 1920))).nodes.count
        )
        for (k, v) in t.theme ?? [:] { #expect(store.project.theme[k] == v) }
        #expect(store.project.theme["fg"] != nil)
        // Exists already → error, blank project gets one empty scene.
        #expect(throws: (any Error).self) {
            try LibraryModel.createProject(
                in: dir.appendingPathComponent("nested"), name: "Launch", size: (1920, 1080), fps: 30, template: nil)
        }
        let blank = try ProjectStore(
            url: try LibraryModel.createProject(in: dir, name: "Blank", size: (1920, 1080), fps: 30, template: nil))
        #expect(blank.orderedScenes.map(\.id) == ["scene-1"] && blank.orderedScenes[0].nodes.isEmpty)
    }

    // MARK: Document actions

    @MainActor @Test(.requiresMetal) func documentLibraryActions() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try LibraryModel.createProject(in: dir, name: "Doc", size: (1920, 1080), fps: 30, template: nil)
        let doc = try EditorDocument(url: url)
        defer { Recents.remove(url) }
        // New scene from a template with a param → opened.
        let counter = try #require(Templates.get("counter", project: nil))
        doc.newScene(from: counter, params: ["value": 12])
        #expect(doc.scene.id == "counter" && doc.scenes.count == 2)
        #expect(doc.scene.node("number")?.props["value"]?.json.compactString.contains("12") == true)
        // Insert into the current scene: prefixed, undoable.
        let before = doc.scene.nodes.count
        doc.insertTemplate(counter, params: [:])
        #expect(doc.scene.nodes.count == before * 2)
        #expect(doc.scene.node("counter-number") != nil && doc.selection == "counter-label")
        doc.undo()
        #expect(doc.scene.nodes.count == before)
        // Repeater from a symbol, then add a symbol to the selected repeater.
        doc.addRepeater(symbol: "chess/knight")
        let rep = try #require(doc.selectedRepeater)
        doc.useSymbolInSelectedRepeater("basic/star")
        #expect(
            doc.scene.node(rep)?.props["items"]
                == .value([["symbol": "chess/knight", "height": 100], ["symbol": "basic/star", "height": 100]]))
        #expect(doc.scene.camera != nil)
        // Scene audio.
        doc.useAsSceneAudio("voice.wav")
        #expect(doc.scene.audio?.src == "voice.wav")
        // Save as template (project scope) and find it again.
        let picks = LibraryModel.candidates(doc.scene).filter { $0.prop == "text" }
        #expect(
            doc.saveTemplate(
                from: doc.scene, id: "mine", name: "Mine", description: nil, category: "Test", scope: .project,
                picks: picks))
        #expect(LibraryModel.templateFiles(project: url).contains { $0.template.id == "mine" && $0.scope == .project })
        doc.saveNow()
    }

    @Test func formValueParsing() {
        #expect(LibraryModel.value("42", kind: "number") == .number(42))
        #expect(LibraryModel.value("x", kind: "number") == nil)
        #expect(LibraryModel.value(#"{"a":1}"#, kind: "json") == .object(["a": 1]))
        #expect(LibraryModel.value("hi", kind: "text") == .string("hi"))
        #expect(LibraryModel.text(.number(72), kind: "number") == "72")
    }
}
