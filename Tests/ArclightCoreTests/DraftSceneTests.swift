import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightMCP

/// Draft scenes for the direction stages: hidden from the scene list and default exports, their own tokens over the
/// project theme, dropped when the real scene is copied from them, cleared in one call.
@Suite struct DraftSceneTests {
    private func run(_ s: MCPServer, _ name: String, _ args: [String: JSONValue]) throws -> String {
        guard let tool = s.tools.first(where: { $0.name == name }) else { throw ToolError("no tool \(name)") }
        return try tool.run(args).compactMap { $0.object?["text"]?.string }.joined(separator: "\n")
    }

    @Test func draftsStayOutOfTheWayAndCarryTheirOwnTokens() throws {
        let tp = try TempProject("drafts")
        let server = MCPServer(projectPath: tp.url.path)
        _ = try run(server, "scene_create", ["id": "main", "nodes": [["id": "t", "type": "text", "text": "Hi"]]])
        _ = try run(
            server, "scene_create",
            [
                "id": "look-a", "draft": true, "duration": 1, "theme": ["accent": "#00E5FF"],
                "nodes": [["id": "t", "type": "text", "text": "Hi", "color": "$accent"]],
            ])
        let store = try ProjectStore(url: tp.url)
        #expect(store.orderedScenes.map(\.id) == ["main"])
        #expect(store.draftScenes.map(\.id) == ["look-a"])
        let look = try store.scene("look-a")
        #expect(look.isDraft)
        #expect(look.theme(over: ["accent": "#FF0000", "bg": "#000"]) == ["accent": "#00E5FF", "bg": "#000"])
        #expect(try run(server, "project_get", [:]).contains("drafts (direction stages"))

        // The real build copies the board but is no draft and uses the project's tokens.
        _ = try run(server, "scene_create", ["id": "intro", "copy_from": "look-a"])
        let intro = try ProjectStore(url: tp.url).scene("intro")
        #expect(!intro.isDraft && intro.theme == nil && intro.nodes.count == 1)

        #expect(try run(server, "scene_delete", ["drafts": true]) == "deleted drafts: look-a")
        let after = try ProjectStore(url: tp.url)
        #expect(after.draftScenes.isEmpty && after.orderedScenes.map(\.id) == ["main", "intro"])
    }

    @Test func guideHasTheDirectionTopic() {
        #expect(Guide.topic("direction")?.contains("ask_choice") == true)
        #expect(Guide.topic("storyboard") == Guide.topic("direction"))
        #expect(Guide.topicNames.contains("direction"))
    }
}
