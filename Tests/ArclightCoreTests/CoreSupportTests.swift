import Foundation
import Testing

@testable import ArclightCore

/// Shared Core helpers: paths, timestamps, JSON formats, change sources.
@Suite struct CoreSupportTests {
    @Test func appPaths() {
        #expect(AppPaths.support.path.hasSuffix("/Library/Application Support/Arclight"))
        #expect(AppPaths.library("templates").path.hasSuffix("/Library/Application Support/Arclight/library/templates"))
        #expect(AppPaths.logs.path.hasSuffix("/Library/Logs/Arclight"))
        #expect(AppPaths.thumbs.path.hasSuffix("/Library/Caches/Arclight/thumbs"))
        #expect(AppPaths.defaultProjects.path.hasSuffix("/Movies/Arclight"))
    }

    @Test func timestamps() throws {
        let d = Date(timeIntervalSince1970: 1_700_000_000.25)
        #expect(Timestamp.string(d) == "2023-11-14T22:13:20.250Z")
        #expect(Timestamp.parse("2023-11-14T22:13:20.250Z") == d)
        #expect(Timestamp.parse("2023-11-14T22:13:20Z") == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(Timestamp.parse("yesterday") == nil)
    }

    struct Sample: Codable, Equatable { var b = "a/b"; var a = 1 }

    @Test func jsonFormats() throws {
        #expect(String(decoding: try JSONFormat.compact().encode(Sample()), as: UTF8.self) == #"{"a":1,"b":"a/b"}"#)
        #expect(
            String(decoding: try JSONFormat.pretty().encode(Sample()), as: UTF8.self)
                == "{\n  \"a\" : 1,\n  \"b\" : \"a/b\"\n}")
    }

    @Test func jsonFilesAndLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-json-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("sub/x.json")
        #expect(JSONFile.read(Sample.self, from: f) == nil)
        try JSONFile.write(Sample(), to: f)
        #expect(JSONFile.read(Sample.self, from: f) == Sample())

        let log = dir.appendingPathComponent("logs/a.jsonl")
        #expect(JSONL.append(Sample(), to: log) == 18)
        #expect(JSONL.append(Sample(a: 2), to: log) == 36)
        #expect(try String(contentsOf: log, encoding: .utf8) == "{\"a\":1,\"b\":\"a/b\"}\n{\"a\":2,\"b\":\"a/b\"}\n")
    }

    /// "claude" is the legacy activity source value for any AI agent, kept so older projects still load.
    @Test func changeSourceRawValuesAreFileFormat() {
        #expect(ChangeSource.ai.rawValue == "claude")
        #expect(ChangeSource.editor.rawValue == "editor")
        #expect(ChangeSource.cli.rawValue == "cli")
        let e = ActivityEntry(source: .ai, tool: "scene_apply", summary: "x", write: true)
        #expect(e.source == "claude" && e.isAI && e.who == "AI")
    }

    @Test func expandingPath() {
        #expect(
            URL(expandingPath: "~/a/../b.arclight").path
                == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("b.arclight").path)
        #expect(URL(expandingPath: "/tmp/x/./y").path == "/tmp/x/y")
    }

    @Test func numberFormat() {
        #expect(
            Format.number(3) == "3" && Format.number(-2) == "-2" && Format.number(0.25) == "0.25"
                && Format.number(1.5e-5) == "1.5e-05")
    }

    @Test func assetPaths() {
        let assets = URL(fileURLWithPath: "/p/assets")
        #expect(AssetPath.url("a.png", assets: assets).path == "/p/assets/a.png")
        #expect(AssetPath.url("/abs/a.png", assets: assets).path == "/abs/a.png")
        #expect(AssetPath.url("a.png", assets: nil).path.hasSuffix("/a.png"))
    }

    @Test func jsonValueDecoded() throws {
        let n = try JSONValue.object(["id": "a", "type": "shape", "x": 4]).decoded(as: Node.self)
        #expect(n.id == "a" && n.props["x"] == .value(4))
        #expect(throws: (any Error).self) { try JSONValue.string("x").decoded(as: Node.self) }
    }
}
