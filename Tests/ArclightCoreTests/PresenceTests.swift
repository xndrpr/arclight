import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightMCP

@Suite(.serialized) struct PresenceTests {
    func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-presence-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func encodeDecodeRoundTrip() throws {
        var a = AgentPresence(pid: 4242, client: "claude-code", clientVersion: "2.1.0", project: "/tmp/A.arclight")
        a.begin("scene_apply", writes: true)
        a.end(summary: "set title (size)", wrote: true, ok: true, project: "/tmp/B.arclight")
        let data = try JSONEncoder().encode(a)
        let b = try JSONDecoder().decode(AgentPresence.self, from: data)
        #expect(a == b)
        #expect(b.projects == ["/tmp/A.arclight", "/tmp/B.arclight"] && b.project == "/tmp/B.arclight")
        #expect(b.lastTool == "scene_apply" && b.tool == nil && b.lastWrite == true)
        // Minimal file from an older/other writer still decodes.
        let min = try JSONDecoder().decode(
            AgentPresence.self, from: Data(#"{"pid":7,"started":"2026-01-01T00:00:00Z","projects":[]}"#.utf8))
        #expect(min.displayName == "AI agent" && min.activity() == .idle)
    }

    @Test func activityFollowsCalls() {
        let now = Date()
        var a = AgentPresence(pid: 1)
        #expect(a.activity(now: now) == .idle)
        a.begin("scene_get", writes: false)
        #expect(a.activity(now: now) == .reading)
        a.end(summary: "read", wrote: false, ok: true, project: nil, at: now)
        #expect(a.activity(now: now.addingTimeInterval(1)) == .reading)
        #expect(a.activity(now: now.addingTimeInterval(AgentPresence.busyWindow + 1)) == .idle)
        a.begin("scene_apply", writes: true)
        #expect(a.activity(now: now) == .editing)
        a.end(summary: "set x", wrote: true, ok: true, project: "/p.arclight", at: now)
        #expect(a.activity(now: now.addingTimeInterval(2)) == .editing)
        #expect(a.uses(URL(fileURLWithPath: "/p.arclight")) && !a.uses(URL(fileURLWithPath: "/q.arclight")))
    }

    @Test func displayNames() {
        #expect(AgentPresence.displayName("claude-code") == "Claude Code")
        #expect(AgentPresence.displayName("claude-ai") == "Claude")
        #expect(AgentPresence.displayName("cursor-vscode") == "Cursor")
        #expect(AgentPresence.displayName("codex-mcp-client") == "Codex")
        #expect(AgentPresence.displayName("my-agent") == "My Agent")
        #expect(AgentPresence.displayName(nil) == "AI agent" && AgentPresence.displayName("  ") == "AI agent")
    }

    @Test func staleEntriesArePruned() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        Presence.write(AgentPresence(pid: 100, client: "cursor"), dir: dir)
        Presence.write(AgentPresence(pid: 200, client: "claude-code"), dir: dir)
        try Data("not json".utf8).write(to: dir.appendingPathComponent("junk.json"))
        let alive: (Int32) -> Bool = { $0 == 200 }
        #expect(Presence.agents(dir: dir, alive: alive, prune: false).count == 1)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("100.json").path))
        let live = Presence.agents(dir: dir, alive: alive)
        #expect(live.map(\.pid) == [200] && live[0].displayName == "Claude Code")
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("100.json").path))
        Presence.remove(pid: 200, dir: dir)
        #expect(Presence.agents(dir: dir, alive: { _ in true }).isEmpty)
        // Missing folder: nothing connected.
        #expect(Presence.agents(dir: dir.appendingPathComponent("nope")).isEmpty)
    }

    @Test func processChecks() {
        #expect(Presence.isAlive(getpid()))
        #expect(!Presence.isAlive(0) && !Presence.isAlive(-1))
        #expect(!Presence.isAlive(Int32.max - 7))
    }

    @Test func editorPresence() {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = URL(fileURLWithPath: "/tmp/x/../Show.arclight")
        Presence.write(EditorPresence(pid: 300, projects: [p.standardizedFileURL.path]), dir: dir)
        #expect(Presence.editorHasOpen(p, dir: dir, alive: { _ in true }))
        #expect(!Presence.editorHasOpen(URL(fileURLWithPath: "/tmp/Other.arclight"), dir: dir, alive: { _ in true }))
        #expect(!Presence.editorHasOpen(p, dir: dir, alive: { _ in false }))
        // An editor with no projects removes its file.
        Presence.write(EditorPresence(pid: 301, projects: ["/a"]), dir: dir)
        Presence.write(EditorPresence(pid: 301, projects: []), dir: dir)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("301.json").path))
    }

    @Test(.requiresMetal) func serverTracksClientAndCalls() throws {
        let project = try TempProject("presence")
        let url = project.url
        defer { project.remove() }
        let server = MCPServer(projectPath: url.path)
        func send(_ msg: JSONValue) { server.handle(String(data: try! JSONEncoder().encode(msg), encoding: .utf8)!) }
        send([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["clientInfo": ["name": "claude-code", "version": "2.0"]],
        ])
        #expect(server.presence.displayName == "Claude Code" && server.presence.clientVersion == "2.0")
        send([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": [
                "name": "scene_create",
                "arguments": ["id": "s", "nodes": [["id": "t", "type": "text", "text": "Hi"]]],
            ],
        ])
        #expect(
            server.presence.lastTool == "scene_create" && server.presence.lastWrite == true
                && server.presence.tool == nil)
        #expect(server.presence.uses(url))
        // Activity entries carry the agent's name.
        #expect(ActivityLog.read(project: url).last?.agent == "Claude Code")
        #expect(ActivityLog.read(project: url).last?.who == "Claude Code")
        send(["jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": ["name": "editor_state", "arguments": [:]]])
        #expect(server.presence.lastWrite == false)
    }

    /// An entry from before agent names were logged, with the legacy activity source value "claude".
    @Test func oldActivityEntriesStillLoad() throws {
        let line =
            #"{"id":"ab","time":"2026-01-01T00:00:00Z","source":"claude","tool":"scene_apply","summary":"x","ok":true,"write":true}"#
        let e = try JSONDecoder().decode(ActivityEntry.self, from: Data(line.utf8))
        #expect(e.agent == nil && e.who == "AI" && e.isAI)
    }
}
