import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightMCP

@Suite(.serialized) struct NotesTests {
    func tempProject() throws -> URL {
        try TempProject("notes").url
    }

    /// Sends one tools/call through the JSON-RPC handler (logs it); returns the tool's text output by running it directly
    /// so the test doesn't have to capture stdout.
    @discardableResult
    func call(_ server: MCPServer, _ tool: String, _ args: JSONValue) -> (text: String, isError: Bool) {
        let msg: JSONValue = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": .string(tool), "arguments": args],
        ]
        server.handle(String(data: try! JSONEncoder().encode(msg), encoding: .utf8)!)
        guard let t = server.tools.first(where: { $0.name == tool }) else { return ("", true) }
        do {
            let out = try t.run(args.object ?? [:])
            return (out.compactMap { $0["text"]?.string }.joined(separator: "\n"), false)
        } catch { return ("\(error)", true) }
    }

    @Test func modelAddResolveReopenDelete() throws {
        let url = try tempProject()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(Notes.load(project: url).isEmpty)
        let a = try Notes.add(Note(text: "slower", scene: "s", layer: "title", time: 2.4), project: url)
        let b = try Notes.add(Note(text: "bigger logo", scene: "s"), project: url)
        #expect(Notes.load(project: url).map(\.id) == [a.id, b.id])
        #expect(a.isOpen && a.target == "s · title @ 2.4s")
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent(".arclight/notes.json").path))

        let r = try Notes.resolve(a.id, reply: "  eased the title in over 0.8s ", project: url)
        #expect(r.status == "resolved" && r.reply == "eased the title in over 0.8s" && r.resolvedDate != nil)
        #expect(Notes.load(project: url).filter(\.isOpen).map(\.id) == [b.id])
        #expect(throws: (any Error).self) { try Notes.resolve("n-nope", project: url) }

        try Notes.reopen(a.id, project: url)
        #expect(Notes.load(project: url).first { $0.id == a.id }?.isOpen == true)
        try Notes.delete(b.id, project: url)
        #expect(Notes.load(project: url).map(\.id) == [a.id])
    }

    @Test func mcpNoteToolsAndEditorState() throws {
        let url = try tempProject()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = MCPServer(projectPath: url.path)
        _ = call(server, "scene_create", ["id": "s", "nodes": [["id": "title", "type": "text", "text": "Hi"]]])
        let n = try Notes.add(Note(text: "make it red", scene: "s", layer: "title", time: 1), project: url)
        _ = try Notes.add(Note(text: "done already", scene: "s"), project: url)
        let other = Notes.load(project: url)[1]

        #expect(call(server, "note_list", [:]).text.contains("make it red"))
        // editor_state lists open notes.
        try Data(#"{"scene":"s","selection":"title","time":1,"playing":false}"#.utf8).write(
            to: url.appendingPathComponent(".state.json"))
        let st = call(server, "editor_state", [:])
        #expect(st.text.contains("open notes") && st.text.contains(n.id) && st.text.contains("s · title @ 1s"))

        let res = call(server, "note_resolve", ["id": .string(n.id), "reply": "title is now #FF0000"])
        #expect(!res.isError && res.text.contains("resolved"))
        #expect(Notes.load(project: url).first { $0.id == n.id }?.reply == "title is now #FF0000")
        #expect(call(server, "note_resolve", ["id": "n-missing"]).isError)
        #expect(call(server, "note_resolve", [:]).isError)

        let open = call(server, "note_list", ["status": "open"]).text
        #expect(open.contains(other.id) && !open.contains(n.id))
        #expect(call(server, "note_list", ["status": "resolved"]).text.contains(n.id))
        #expect(call(server, "note_list", ["status": "all"]).text.split(separator: "\n").count == 2)
        #expect(!call(server, "editor_state", [:]).text.contains(n.id))

        // Both are logged: list as a read, resolve as a write with a readable summary.
        let log = ActivityLog.read(project: url)
        let list = log.first { $0.tool == "note_list" }, resolve = log.first { $0.tool == "note_resolve" && $0.ok }
        #expect(list?.write == false && list?.summary == "read notes")
        #expect(resolve?.write == true && resolve?.summary == "resolve note \(n.id) — title is now #FF0000")
    }
}
