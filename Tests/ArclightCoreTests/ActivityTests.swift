import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightMCP

@Suite(.serialized) struct ActivityTests {
    func tempProject() throws -> URL {
        try TempProject("act").url
    }

    func call(_ server: MCPServer, _ id: Int, _ tool: String, _ args: JSONValue) {
        let msg: JSONValue = [
            "jsonrpc": "2.0", "id": .number(Double(id)), "method": "tools/call",
            "params": ["name": .string(tool), "arguments": args],
        ]
        server.handle(String(data: try! JSONEncoder().encode(msg), encoding: .utf8)!)
    }

    @Test(.requiresMetal) func mcpCallsAreLoggedWithSummariesAndChanges() throws {
        let url = try tempProject()
        defer { try? FileManager.default.removeItem(at: url) }
        let server = MCPServer(projectPath: url.path)
        call(server, 1, "scene_create", ["id": "s", "nodes": [["id": "title", "type": "text", "text": "Hi"]]])
        call(server, 2, "scene_get", ["scene": "s"])
        call(
            server, 3, "scene_apply",
            [
                "scene": "s",
                "ops": [
                    ["op": "set", "id": "title", "size": 140],
                    ["op": "add", "node": ["id": "dot", "type": "shape"]],
                ],
            ])
        call(server, 4, "scene_apply", ["scene": "s", "ops": [["op": "set", "id": "missing", "x": 1]]])
        let log = ActivityLog.read(project: url)
        #expect(log.map(\.tool) == ["scene_create", "scene_get", "scene_apply", "scene_apply"])
        #expect(log.allSatisfy { $0.source == "claude" })  // the legacy activity source value, stored for every agent
        #expect(log[0].write && log[0].revAfter == 1 && log[0].changed == ["title"])
        #expect(!log[1].write && log[1].summary == "read scene outline")
        #expect(log[2].summary == "set title (size); add dot" && log[2].revBefore == 1 && log[2].revAfter == 2)
        #expect(Set(log[2].changed ?? []) == ["title", "dot"])
        #expect(!log[3].ok && log[3].error?.contains("missing") == true)
        // History records who saved.
        let hist = try ProjectStore(url: url).history("s")
        #expect(hist.last?.source == "claude" && hist.last?.changed?.contains("dot") == true)
    }

    @Test func sceneDiff() {
        var a = Scene(id: "s")
        a.nodes = [Node(id: "a", type: "group"), Node(id: "b", type: "group")]
        var b = a
        b.nodes[0].props["x"] = .value(1)
        b.nodes.remove(at: 1)
        b.nodes.append(Node(id: "c", type: "group"))
        b.duration = 9
        let d = SceneDiff.diff(a, b)
        #expect(d.added == ["c"] && d.removed == ["b"] && d.modified == ["a"] && d.sceneChanged)
        #expect(d.summary == "added c; removed b; changed a; scene settings")
    }
}
