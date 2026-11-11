import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightMCP

/// Names that become file names are rejected, never rewritten, when they could leave their folder (B7).
@Suite struct SafeNameTests {
    static let escapes = ["..", ".", "../x", "../../x", "a/b", "/tmp/x", "/", "a/../b", ".hidden", "a\nb", "a\0b", ""]

    @Test(arguments: escapes) func everyCheckRejectsPathsAndEmptyNames(_ s: String) {
        #expect(throws: ModelError.self) { try SafeName.id(s) }
        #expect(throws: ModelError.self) { try SafeName.fileName(s) }
        #expect(throws: ModelError.self) { try SafeName.component(s) }
        #expect(!SafeName.isComponent(s))
    }

    @Test func idsAcceptLettersDigitsDashUnderscore() throws {
        for s in ["intro", "stat-45", "A_b-9", String(repeating: "x", count: SafeName.maxLength)] {
            #expect(try SafeName.id(s) == s)
        }
        for s in ["a b", "a.b", "é", "x:y", String(repeating: "x", count: SafeName.maxLength + 1)] {
            #expect(throws: ModelError.self) { try SafeName.id(s) }
        }
    }

    @Test func fileNamesAcceptPlainNamesWithExtension() throws {
        for s in ["badge.png", "My Logo 2.jpg", "a..b.png", "-x.png", "_x"] { #expect(try SafeName.fileName(s) == s) }
        for s in [" badge.png", "a\\b.png", "a:b.png", "emoji😀.png", String(repeating: "x", count: 125) + ".png"] {
            #expect(throws: ModelError.self) { try SafeName.fileName(s) }
        }
    }

    @Test func componentsAcceptAnythingAFilePickerProduces() throws {
        for s in ["Screen Shot 2026-11-11 at 10.00.00\u{202F}AM.png", "Фото 1.png", "a..b", "x:y"] {
            #expect(try SafeName.component(s) == s)
        }
        #expect(throws: ModelError.self) { try SafeName.component(String(repeating: "é", count: 121)) }  // 242 bytes
    }

    @Test func messagesNameTheArgument() {
        do {
            try SafeName.id("../x", what: "scene")
            Issue.record("not rejected")
        } catch { #expect("\(error)" == "scene may only contain letters, digits, - and _") }
    }
}

/// The store and the template library refuse names that leave their folder, so the editor is covered too.
@Suite struct SafeNameStoreTests {
    struct Box {
        let parent: URL
        let store: ProjectStore
        init() throws {
            parent = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-sn-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            store = try ProjectStore.create(at: parent.appendingPathComponent("p.arclight"), name: "p")
        }
        func remove() { try? FileManager.default.removeItem(at: parent) }
        /// Files and folders under `parent` other than the project.
        func outside() -> [String] {
            (FileManager.default.enumerator(atPath: parent.path)?.allObjects as? [String] ?? [])
                .filter { $0 != "p.arclight" && !$0.hasPrefix("p.arclight/") }
        }
    }

    @Test(arguments: ["../../esc", "/tmp/esc-\(UUID().uuidString)", "a/b", "", ".."])
    func storeRejectsUnsafeNames(_ bad: String) throws {
        let box = try Box()
        defer { box.remove() }
        let src = box.parent.appendingPathComponent("src.png")
        try Data([1]).write(to: src)
        #expect(throws: ModelError.self) { try box.store.save(scene: Scene(id: bad, duration: 1)) }
        #expect(throws: ModelError.self) { try box.store.importAsset(from: src, name: bad) }
        #expect(throws: ModelError.self) { try box.store.deleteScene(bad) }
        #expect(throws: ModelError.self) { try box.store.revert(bad, to: 1) }
        #expect(box.store.history(bad).isEmpty)
        #expect(box.store.snapshot(bad, rev: 1) == nil)
        let t = Template(id: bad, name: "x", params: [], scene: ["id": "x"])
        #expect(throws: ModelError.self) { try Templates.save(t, scope: .project, project: box.store.url) }
        try? FileManager.default.removeItem(at: src)
        #expect(box.outside().isEmpty, "\(box.outside())")
        if bad.hasPrefix("/") { #expect(!FileManager.default.fileExists(atPath: bad + ".json")) }
    }

    @Test func storeKeepsAcceptingOrdinaryNames() throws {
        let box = try Box()
        defer { box.remove() }
        let src = box.parent.appendingPathComponent("Фото 1.png")
        try Data([1]).write(to: src)
        #expect(try box.store.importAsset(from: src) == "Фото 1.png")
        try box.store.save(scene: Scene(id: "intro", duration: 1))
        #expect(box.store.scenes["intro"] != nil)
    }

    /// Every MCP tool argument that becomes a file name is checked, not only the three the audit found.
    /// `why` is a fragment of the expected message, so the call fails for the name and not for another reason.
    static let svg = "<svg xmlns='http://www.w3.org/2000/svg' width='4' height='4'><rect width='4' height='4'/></svg>"
    @Test(
        arguments: [
            ("asset_write", ["name": "../../esc.png", "svg": svg], "plain file name"),
            ("asset_write", ["name": "/tmp/esc.png", "svg": svg], "plain file name"),
            ("asset_import", ["path": "$SRC", "name": "sub/esc.png"], "plain file name"),
            ("symbol_save", ["pack": "../../esc", "id": "x", "path": "M0 0 L10 0 L10 10 Z"], "pack may only"),
            ("symbol_save", ["pack": "brand", "id": "../esc", "path": "M0 0 L10 0 L10 10 Z"], "id may only"),
            ("template_save", ["scene": "a", "id": "a/b", "name": "X"], "id may only"),
            ("template_save", ["scene": "a", "id": String(repeating: "x", count: 129), "name": "X"], "longer than"),
            ("template_instantiate", ["template": "stat-crowd", "scene": "/tmp/esc"], "scene may only"),
            ("scene_create", ["id": "../esc"], "id may only"),
            ("history", ["scene": "../../esc", "revert_to": "1"], "not a valid file name"),
        ] as [(String, [String: String], String)])
    func mcpToolsRejectUnsafeNames(_ tool: String, _ raw: [String: String], _ why: String) throws {
        let box = try Box()
        defer { box.remove() }
        try box.store.save(scene: Scene(id: "a", duration: 1))
        let src = box.parent.appendingPathComponent("src.png")
        try Data([1]).write(to: src)
        var args: [String: JSONValue] = [:]
        for (k, v) in raw {
            args[k] = k == "revert_to" ? .number(Double(v) ?? 0) : .string(v == "$SRC" ? src.path : v)
        }
        let server = MCPServer(projectPath: box.store.url.path)
        let t = try #require(server.tools.first { $0.name == tool })
        do {
            _ = try t.run(args)
            Issue.record("\(tool) accepted \(raw)")
        } catch { #expect("\(error)".contains(why), "\(error)") }
        try? FileManager.default.removeItem(at: src)
        #expect(box.outside().isEmpty, "\(box.outside())")
        #expect(!FileManager.default.fileExists(atPath: "/tmp/esc.png"))
    }
}
