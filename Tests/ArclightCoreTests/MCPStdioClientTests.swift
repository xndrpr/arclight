import Foundation
import Testing

@testable import ArclightCore

private final class Anchor {}

/// The chat's MCP client against the real `arclight mcp` binary built next to the tests.
@Suite(.serialized) struct MCPStdioClientTests {
    @Test(.requiresMetal) func handshakeListsToolsAndCallsAreLoggedUnderTheChatsName() async throws {
        let bundle = Bundle(for: Anchor.self)
        let bin = URL(fileURLWithPath: bundle.bundlePath).deletingLastPathComponent().appendingPathComponent("arclight")
        try #require(FileManager.default.isExecutableFile(atPath: bin.path), "arclight binary missing next to tests")
        let tp = try TempProject("chat-mcp")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("chat-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("home"), withIntermediateDirectories: true)
        defer { tp.remove(); try? FileManager.default.removeItem(at: tmp) }
        var env = ProcessInfo.processInfo.environment
        env["CFFIXED_USER_HOME"] = tmp.appendingPathComponent("home").path
        env["ARCLIGHT_PRESENCE_DIR"] = tmp.appendingPathComponent("presence").path

        let client = MCPStdioClient(
            transport: ProcessTransport(
                executable: bin, arguments: ["mcp", "--project", tp.url.path], environment: env))
        defer { client.close() }
        try await client.connect(clientName: "arclight-chat", version: "test")
        #expect(client.tools.contains { $0.name == "scene_create" })
        #expect(client.tools.allSatisfy { $0.inputSchema["type"]?.string == "object" })
        #expect(!client.instructions.isEmpty)

        let (content, isError) = try await client.call(
            "scene_create", ["id": "hello", "duration": 2, "nodes": []])
        #expect(!isError, "\(content)")
        let (_, bad) = try await client.call("scene_get", ["scene": "nope"])
        #expect(bad)
        let entries = ActivityLog.read(project: tp.url)
        #expect(entries.contains { $0.tool == "scene_create" && $0.agent == "Arclight Chat" })
    }
}
