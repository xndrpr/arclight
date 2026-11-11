import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightMCP

// Regression tests for the MCP and project-store bugs found in the 0.1.0 release work (B4, B7, B8, B11, E8): each
// test states the correct behaviour.

/// A scratch parent folder holding a project, so a path that escapes the project lands somewhere inspectable.
private struct Sandbox {
    let parent: URL
    let project: URL
    let store: ProjectStore

    init(scene: ArclightCore.Scene? = nil) throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arclight-ki-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        project = parent.appendingPathComponent("p.arclight")
        store = try ProjectStore.create(at: project, name: "p")
        if let scene { try store.save(scene: scene) }
    }

    func remove() { try? FileManager.default.removeItem(at: parent) }

    /// Everything below `parent` (recursively, relative paths) except the project folder's own contents.
    func outsideProject() -> [String] {
        let fm = FileManager.default
        let all = fm.enumerator(atPath: parent.path)?.allObjects as? [String] ?? []
        return all.filter { $0 != "p.arclight" && !$0.hasPrefix("p.arclight/") }.sorted()
    }
}

private func sampleScene(_ id: String = "a") -> ArclightCore.Scene {
    var s = ArclightCore.Scene(id: id, duration: 1)
    s.nodes = [Node(id: "t", type: "text", props: ["text": .value("hi"), "size": .value(40)])]
    return s
}

extension MCPServer {
    /// Runs a tool in-process; returns the error text if it threw (an `isError` result), nil on success.
    fileprivate func failure(_ name: String, _ args: [String: JSONValue]) -> String? {
        guard let tool = tools.first(where: { $0.name == name }) else { return "no such tool \(name)" }
        do { _ = try tool.run(args); return nil } catch { return "\(error)" }
    }
}

private final class BundleAnchor {}

/// Runs the built `arclight mcp` binary with JSON-RPC lines on stdin.
private enum MCPChild {
    struct Outcome {
        var reason: Process.TerminationReason
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func binary() throws -> URL {
        let bundle = Bundle(for: BundleAnchor.self)
        try #require(bundle.bundlePath.hasSuffix(".xctest"), "test bundle not found: \(bundle.bundlePath)")
        let url = URL(fileURLWithPath: bundle.bundlePath).deletingLastPathComponent().appendingPathComponent("arclight")
        try #require(FileManager.default.isExecutableFile(atPath: url.path), "arclight binary missing next to tests")
        return url
    }

    /// Sends `initialize` and then one `tools/call` (id 2) to `arclight mcp --project <project>`.
    static func call(project: URL?, tool: String, arguments: String) throws -> Outcome {
        let bin = try binary()
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("arclight-ki-child-\(UUID().uuidString)")
        let home = tmp.appendingPathComponent("home"), presence = tmp.appendingPathComponent("presence")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: presence, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let inURL = tmp.appendingPathComponent("in.jsonl"), outURL = tmp.appendingPathComponent("out.txt")
        let errURL = tmp.appendingPathComponent("err.txt")
        let input = """
            {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ki","version":"1"}}}
            {"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"\(tool)","arguments":\(arguments)}}

            """
        try input.write(to: inURL, atomically: true, encoding: .utf8)
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        let p = Process()
        p.executableURL = bin
        p.arguments = ["mcp"] + (project.map { ["--project", $0.path] } ?? [])
        var env = ProcessInfo.processInfo.environment
        env["CFFIXED_USER_HOME"] = home.path
        env["ARCLIGHT_PRESENCE_DIR"] = presence.path
        p.environment = env
        p.standardInput = try FileHandle(forReadingFrom: inURL)
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        p.standardError = try FileHandle(forWritingTo: errURL)
        try p.run()
        p.waitUntilExit()
        return Outcome(
            reason: p.terminationReason, status: p.terminationStatus,
            stdout: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
            stderr: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
    }

    /// Whether the process answered the request with id 2.
    static func answeredCall(_ o: Outcome) -> Bool {
        o.stdout.split(separator: "\n").contains { line in
            guard let v = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else { return false }
            return v["id"]?.double == 2
        }
    }
}

@Suite(.serialized) struct MCPRegressionTests {
    // MARK: B7 — ids and names that reach the file system are checked

    /// B7: `template_instantiate` must reject a scene id that is a path (as `scene_create` does) and write nothing outside the project.
    @Test(.requiresMetal) func b7_templateInstantiateRejectsSceneIdsThatLeaveTheProject() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let server = MCPServer(projectPath: box.project.path)
        // Control: scene_create validates its id.
        #expect(server.failure("scene_create", ["id": "../../esc-control"]) != nil)
        #expect(box.outsideProject().isEmpty)
        let err = server.failure(
            "template_instantiate", ["template": "stat-crowd", "scene": "../../esc-template"])
        let outside = box.outsideProject()
        #expect(err != nil, "call is rejected")
        #expect(outside.isEmpty, "nothing written outside the project: \(outside)")
    }

    /// B7: `asset_import` must reject a `name` that is a path and write nothing outside the project.
    @Test func b7_assetImportRejectsNamesThatLeaveTheProject() throws {
        let box = try Sandbox()
        let srcDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arclight-ki-src-\(UUID().uuidString)")
        defer { box.remove(); try? FileManager.default.removeItem(at: srcDir) }
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let src = srcDir.appendingPathComponent("in.png")
        try Data([1, 2, 3]).write(to: src)
        let server = MCPServer(projectPath: box.project.path)
        let err = server.failure("asset_import", ["path": .string(src.path), "name": "../../esc-asset.png"])
        let outside = box.outsideProject()
        #expect(err != nil, "call is rejected")
        #expect(outside.isEmpty, "nothing written outside the project: \(outside)")
    }

    /// B7: `template_save` (project scope; user scope writes under the home folder and is not run here) must reject an id that is a path.
    @Test func b7_templateSaveRejectsIdsThatLeaveTheLibrary() throws {
        let box = try Sandbox(scene: sampleScene("a"))
        defer { box.remove() }
        let server = MCPServer(projectPath: box.project.path)
        let err = server.failure(
            "template_save", ["scene": "a", "id": "../../esc-tpl", "name": "X", "scope": "project"])
        let outside = box.outsideProject()
        #expect(err != nil, "call is rejected")
        #expect(outside.isEmpty, "nothing written outside the project: \(outside)")
    }

    // MARK: B4 — importing a file already in assets/ keeps it

    /// B4: importing a file that is already in assets/ must leave it in place.
    @Test func b4_importingAnAssetOntoItselfKeepsIt() throws {
        let box = try Sandbox()
        defer { box.remove() }
        try FileManager.default.createDirectory(at: box.store.assetsURL, withIntermediateDirectories: true)
        let file = box.store.assetsURL.appendingPathComponent("a.png")
        try Data([9, 8, 7]).write(to: file)
        #expect(try box.store.importAsset(from: file) == "a.png")
        #expect((try? Data(contentsOf: file)) == Data([9, 8, 7]), "file still in assets/ with its content")
        // The same file reached through a symlink, or named with other case on a case-insensitive volume.
        let link = box.parent.appendingPathComponent("link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(try box.store.importAsset(from: link, name: "a.png") == "a.png")
        #expect((try? Data(contentsOf: file)) == Data([9, 8, 7]), "kept after importing through a symlink")
        let upper = box.store.assetsURL.appendingPathComponent("A.png")
        if FileManager.default.fileExists(atPath: upper.path) {  // case-insensitive volume
            _ = try box.store.importAsset(from: upper, name: "a.png")
            #expect((try? Data(contentsOf: file)) == Data([9, 8, 7]), "kept after a case-only rename")
        }
        // A different file with the same name still replaces the asset.
        let other = box.parent.appendingPathComponent("a.png")
        try Data([1]).write(to: other)
        _ = try box.store.importAsset(from: other)
        #expect((try? Data(contentsOf: file)) == Data([1]))
    }

    // MARK: B8 — huge, negative or non-finite numbers are refused, not trapped on

    struct TrapCase: CustomTestStringConvertible, Sendable {
        var name: String
        var tool: String
        /// JSON arguments; `$P` is replaced by a path inside the scratch folder.
        var arguments: String
        var openProject = true
        /// Whether the call is refused; an out-of-range layer index is clamped instead, as before.
        var refused = true
        var testDescription: String { name }
    }

    // Reachable `Int(Double)` / `suffix(Int)` sites found by grep:
    //   Tools+Editor.swift:95   history limit (negative and huge)      Tools+Editor.swift:91,93  revert_to
    //   Server+Activity.swift:55 describe() of revert_to (also hit by log() after a throw)
    //   Tools+Project.swift:45  project_create size                    Tools+Project.swift:86   project_update size (guard only checks >= 16)
    //   Tools+Library.swift:134 asset_write width                      Tools+Scene.swift:95     scene_apply rev
    //   SceneOps.swift:115      add/move/duplicate index               SceneOps.swift:220       scene op size
    static let trapCases: [TrapCase] = [
        .init(name: "history limit -1", tool: "history", arguments: #"{"scene":"a","limit":-1}"#),
        .init(name: "history limit 1e300", tool: "history", arguments: #"{"scene":"a","limit":1e300}"#),
        .init(name: "history revert_to 1e300", tool: "history", arguments: #"{"scene":"a","revert_to":1e300}"#),
        .init(
            name: "project_update size 1e300", tool: "project_update", arguments: #"{"size":[1e300,1e300]}"#),
        .init(
            name: "project_create size 1e300", tool: "project_create",
            arguments: #"{"path":"$P/new.arclight","size":[1e300,1e300]}"#, openProject: false),
        .init(
            name: "asset_write width 1e300", tool: "asset_write",
            arguments:
                #"{"name":"b.png","width":1e300,"svg":"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"8\" height=\"8\"><rect width=\"8\" height=\"8\"/></svg>"}"#
        ),
        .init(
            name: "scene_apply rev 1e300", tool: "scene_apply",
            arguments: #"{"scene":"a","rev":1e300,"ops":[{"op":"scene","name":"x"}]}"#),
        .init(
            name: "scene_apply add index 1e300", tool: "scene_apply",
            arguments: #"{"scene":"a","ops":[{"op":"add","index":1e300,"node":{"id":"n","type":"group"}}]}"#,
            refused: false),
        .init(
            name: "scene_apply move index -1e300", tool: "scene_apply",
            arguments: #"{"scene":"a","ops":[{"op":"move","id":"t","index":-1e300}]}"#, refused: false),
        .init(
            name: "scene_apply scene size 1e300", tool: "scene_apply",
            arguments: #"{"scene":"a","ops":[{"op":"scene","size":[1e300,5]}]}"#),
        // Found while fixing: values that overflow later, in the exporter.
        .init(name: "export scale 1e300", tool: "export", arguments: #"{"scale":1e300,"out_dir":"$P/x"}"#),
        .init(name: "export fps 1e300", tool: "export", arguments: #"{"fps":1e300,"out_dir":"$P/x"}"#),
        .init(
            name: "scene_apply scene fps 1e300", tool: "scene_apply",
            arguments: #"{"scene":"a","ops":[{"op":"scene","fps":1e300}]}"#),
        .init(
            name: "scene_apply scene duration 1e300", tool: "scene_apply",
            arguments: #"{"scene":"a","ops":[{"op":"scene","duration":1e300}]}"#),
        .init(
            name: "scene_create duration 1e300", tool: "scene_create",
            arguments: #"{"id":"b","duration":1e300}"#),
        .init(
            name: "project_update fps 1e300", tool: "project_update", arguments: #"{"fps":1e300}"#),
    ]

    /// B8: an out-of-range number must produce an error reply, not crash the server; the process must exit normally and answer the request.
    /// Opt-in (`ARCLIGHT_TEST_TRAPS=1 swift test --filter b8_`): should the bug come back, every case crashes a
    /// child process, and macOS writes a crash report to ~/Library/Logs/DiagnosticReports for each one. The default
    /// suite covers the same checks in-process (SafeNumberTests).
    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["ARCLIGHT_TEST_TRAPS"] != nil,
            "B8 crashes child processes; set ARCLIGHT_TEST_TRAPS=1 to run"),
        arguments: trapCases)
    func b8_numbersDoNotTrapTheServer(_ c: TrapCase) throws {
        let box = try Sandbox(scene: sampleScene("a"))
        defer { box.remove() }
        let out = try MCPChild.call(
            project: c.openProject ? box.project : nil, tool: c.tool,
            arguments: c.arguments.replacingOccurrences(of: "$P", with: box.parent.path))
        #expect(out.reason == .exit, "terminated by signal \(out.status): \(out.stderr.prefix(200))")
        #expect(out.status == 0)
        #expect(MCPChild.answeredCall(out), "request answered")
        #expect(out.stdout.contains(#""isError":true"#) == c.refused, "refused: \(c.refused)")
    }

    // MARK: B11 — validation gaps

    /// B11a: `project_create` must reject a size below 16 and an fps <= 0, as `project_update` does, before creating anything.
    @Test(arguments: [
        #"{"size":[4,4]}"#, #"{"size":[-100,5]}"#, #"{"fps":0}"#, #"{"fps":-30}"#,
    ]) func b11a_projectCreateChecksSizeAndFps(_ extra: String) throws {
        let box = try Sandbox()
        defer { box.remove() }
        let server = MCPServer(projectPath: nil)
        var args = try JSONDecoder().decode(JSONValue.self, from: Data(extra.utf8)).object ?? [:]
        args["path"] = .string(box.parent.appendingPathComponent("made.arclight").path)
        let err = server.failure("project_create", args)
        // Control: project_update validates.
        let opened = MCPServer(projectPath: box.project.path)
        let controlRejects = opened.failure("project_update", args.filter { $0.key != "path" }) != nil
        #expect(controlRejects, "project_update rejects \(extra)")
        #expect(err != nil, "call is rejected")
        #expect(!FileManager.default.fileExists(atPath: box.parent.appendingPathComponent("made.arclight").path))
    }

    /// B11b: a `template_instantiate` that fails must leave project.json (theme) untouched.
    @Test(.requiresMetal) func b11b_templateInstantiateChecksBeforeChangingTheTheme() throws {
        let box = try Sandbox()
        defer { box.remove() }
        let before = box.store.project.theme
        let server = MCPServer(projectPath: box.project.path)
        // spotlight-cascade declares theme tokens (ink, pool); the unknown parameter fails after that step.
        let err = server.failure(
            "template_instantiate",
            ["template": "spotlight-cascade", "scene": "s", "params": ["nope": 1]])
        try #require(err != nil, "setup: the call must fail")
        let after = try ProjectStore(url: box.project).project.theme
        #expect(before["ink"] == nil, "setup: token absent before")
        #expect(after == before, "theme unchanged, got extra keys \(Set(after.keys).subtracting(before.keys))")
        // The same call without the bad parameter still adds the tokens it needs.
        #expect(server.failure("template_instantiate", ["template": "spotlight-cascade", "scene": "s"]) == nil)
        #expect(try ProjectStore(url: box.project).project.theme["ink"] != nil)
    }

    /// B11c: every argument the `template_save` handler reads (`category`) must be declared in its input schema.
    @Test func b11c_templateSaveDeclaresCategory() throws {
        let server = MCPServer(projectPath: nil)
        let tool = try #require(server.tools.first { $0.name == "template_save" })
        let props = try #require(tool.schema["properties"]?.object)
        #expect(props["scope"] != nil, "control: a declared argument is found")
        #expect(props["category"] != nil)
    }

    // MARK: E8 — read-only calls are logged to the activity feed (by design)

    struct ReadCall: CustomTestStringConvertible, Sendable {
        var tool: String
        var arguments: String
        var testDescription: String { tool }
    }

    /// E8 (closed, by design): a read-only call appends one `write: false` entry to `<project>/.arclight/activity.jsonl`,
    /// which is what the editor's activity feed shows, and changes no other file in the project.
    @Test(arguments: [
        ReadCall(tool: "project_get", arguments: "{}"),
        ReadCall(tool: "scene_get", arguments: #"{"scene":"a"}"#),
        ReadCall(tool: "note_list", arguments: "{}"),
    ]) func e8_readOnlyCallsAreLoggedAndTouchNothingElse(_ c: ReadCall) throws {
        let box = try Sandbox(scene: sampleScene("a"))
        defer { box.remove() }
        let log = ActivityLog.url(box.project)
        try #require(!FileManager.default.fileExists(atPath: log.path), "setup: no activity log yet")
        func files() -> [String: Data] {
            let all = FileManager.default.enumerator(atPath: box.project.path)?.allObjects as? [String] ?? []
            var out: [String: Data] = [:]
            for f in all where f != ".arclight/activity.jsonl" {
                if let d = try? Data(contentsOf: box.project.appendingPathComponent(f)) { out[f] = d }
            }
            return out
        }
        let server = MCPServer(projectPath: box.project.path)
        let before = files()
        try #require(server.tools.first { $0.name == c.tool }?.readOnly == true, "setup: \(c.tool) is read-only")
        let line =
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(c.tool)","arguments":\#(c.arguments)}}"#
        server.handle(line)
        let entries = ActivityLog.read(project: box.project)
        #expect(entries.count == 1)
        #expect(entries.first?.tool == c.tool && entries.first?.write == false && entries.first?.ok == true)
        #expect(files() == before, "a read changes no other project file")
    }
}
