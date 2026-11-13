import Foundation
import ImageIO
import Testing

@testable import ArclightCore
@testable import ArclightMCP

/// The preview tools end to end, in-process: create → apply → render → export → history, as an agent uses them.
@Suite(.requiresMetal) struct PreviewMCPTests {
    private func run(_ s: MCPServer, _ name: String, _ args: [String: JSONValue]) throws -> [JSONValue] {
        guard let tool = s.tools.first(where: { $0.name == name }) else { throw ToolError("no tool \(name)") }
        return try tool.run(args)
    }

    private func text(_ out: [JSONValue]) -> String {
        out.compactMap { $0.object?["text"]?.string }.joined(separator: "\n")
    }

    private func server() throws -> (MCPServer, TempProject) {
        let tp = try TempProject("preview-mcp")
        return (MCPServer(projectPath: tp.url.path), tp)
    }

    private let thumb: [String: JSONValue] = [
        "id": "ep12",
        "name": "Episode 12",
        "artboards": [
            [
                "id": "a", "name": "A",
                "nodes": [
                    ["id": "title", "type": "text", "text": "I QUIT", "size": 160, "color": "$fg", "x": 80, "y": 420],
                    ["id": "bar", "type": "shape", "shape": "rect", "width": 400, "height": 40, "fill": "$accent"],
                ],
            ],
            ["id": "shorts", "size": "shorts"],
        ],
    ]

    @Test func createApplyRenderExport() throws {
        let (s, tp) = try server()
        defer { tp.remove() }
        let created = text(try run(s, "preview_create", thumb))
        #expect(created.contains("saved preview ep12 rev 1"))
        #expect(created.contains("artboard shorts \"\"") == false)
        let p = try #require(tp.store.previews["ep12"] ?? (try? ProjectStore(url: tp.url))?.previews["ep12"])
        #expect(p.artboards.map(\.id) == ["a", "shorts"])
        #expect(p.artboards[1].size == [1080, 1920])
        #expect(p.artboards[1].x == 1280 + 120)  // laid out left to right

        // Variant B: duplicate and change one thing, in one atomic call.
        let applied = text(
            try run(
                s, "preview_apply",
                [
                    "preview": "ep12",
                    "ops": [
                        ["op": "artboard_duplicate", "id": "a", "as": "b", "name": "B"],
                        ["op": "set", "artboard": "b", "id": "title", "text": "I'M DONE"],
                    ],
                ]))
        #expect(applied.contains("rev 2"))
        #expect(applied.contains("b/title"))
        let store = try ProjectStore(url: tp.url)
        let b = try #require(store.previews["ep12"]?.artboard("b"))
        #expect(b.nodes.first?.props["text"] == .value("I'M DONE"))
        #expect(store.previews["ep12"]?.artboard("a")?.nodes.first?.props["text"] == .value("I QUIT"))

        // A text layer's font size is a number, not an artboard size preset.
        let sized = text(try run(s, "preview_apply", ["preview": "ep12", "ops": [["op": "set", "id": "title", "size": 84]]]))
        #expect(sized.contains("size=84"))
        _ = try run(s, "preview_apply", ["preview": "ep12", "ops": [["op": "set", "id": "title", "size": 160]]])
        // Bad layer props are refused and nothing is saved.
        let bad = try? run(
            s, "preview_apply", ["preview": "ep12", "ops": [["op": "set", "id": "title", "colour": "#fff"]]])
        #expect(bad == nil)
        #expect(try ProjectStore(url: tp.url).previews["ep12"]?.rev == 4)

        // Render: one image block plus a label line, with feed mock-ups.
        let r = try run(s, "preview_render", ["preview": "ep12", "feed": true, "scale": 0.2])
        #expect(r.first?.object?["type"]?.string == "image")
        #expect(text(r).contains("a feed"))

        // Export: YouTube preset → 1280×720 JPGs under 2 MB; the Shorts artboard keeps its size.
        let out = text(try run(s, "export", ["preview": "ep12", "artboards": ["a", "shorts"]]))
        let files = out.split(separator: "\n").map { String($0.split(separator: " ").first ?? "") }
        #expect(files.count == 2)
        for f in files {
            let url = URL(fileURLWithPath: f)
            let size = try #require(try FileManager.default.attributesOfItem(atPath: f)[.size] as? Int)
            #expect(size < StillExporter.youtubeMaxBytes)
            let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
            let w = props[kCGImagePropertyPixelWidth] as? Int, h = props[kCGImagePropertyPixelHeight] as? Int
            if f.hasSuffix("ep12_a.jpg") { #expect(w == 1280 && h == 720) }
            if f.hasSuffix("ep12_shorts.jpg") { #expect(w == 1080 && h == 1920) }
        }
        let png = text(try run(s, "export", ["preview": "ep12", "artboards": ["b"], "format": "png", "scale": 0.5]))
        #expect(png.contains("ep12_b.png") && png.contains("640x360"))
    }

    @Test func outlineHistoryThemeAndDelete() throws {
        let (s, tp) = try server()
        defer { tp.remove() }
        _ = try run(s, "preview_create", thumb)
        let outline = text(try run(s, "preview_get", ["preview": "ep12"]))
        #expect(outline.contains("artboard a \"A\"  1280x720"))
        #expect(outline.contains("title text"))
        let json = text(try run(s, "preview_get", ["preview": "ep12", "artboard": "a", "ids": ["title"]]))
        #expect(json.contains("\"I QUIT\""))

        _ = try run(
            s, "preview_apply",
            ["preview": "ep12", "ops": [["op": "preview", "theme": ["detached": true, "tokens": ["accent": "#FF0044"]]]]])
        let st = try ProjectStore(url: tp.url)
        #expect(st.project.theme(for: try st.preview("ep12"))["accent"] == "#FF0044")
        #expect(text(try run(s, "project_get", [:])).contains("preview ep12"))

        let hist = text(try run(s, "history", ["preview": "ep12"]))
        #expect(hist.contains("rev 1") && hist.contains("rev 2"))
        _ = try run(s, "history", ["preview": "ep12", "revert_to": 1])
        #expect(try ProjectStore(url: tp.url).preview("ep12").theme == .project)

        #expect(text(try run(s, "preview_list", [:])).contains("ep12"))
        _ = try run(s, "preview_delete", ["preview": "ep12"])
        #expect(try ProjectStore(url: tp.url).previews.isEmpty)
    }

    @Test func previewOnlyProjectAndGuide() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-pv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let s = MCPServer(projectPath: nil)
        let path = parent.appendingPathComponent("Thumbs.arclight").path
        _ = try run(s, "project_create", ["path": .string(path), "start": "preview"])
        _ = try run(s, "preview_create", ["id": "t"])
        let st = try ProjectStore(url: URL(fileURLWithPath: path))
        #expect(st.project.workspace == "preview")
        #expect(st.scenes.isEmpty)
        #expect(st.previews["t"]?.artboards.first?.size == [1280, 720])
        #expect(text(try run(s, "guide", ["topic": "previews"])).contains("artboard_duplicate"))
        #expect(Guide.instructions.contains("preview_create"))
        #expect((try? run(s, "preview_create", ["id": "t"])) == nil)  // exists → preview_apply or overwrite
        #expect((try? run(s, "preview_create", ["id": "bad/id"])) == nil)
        #expect((try? run(s, "preview_create", ["id": "u", "artboards": [["id": "x", "size": "huge"]]])) == nil)
    }
}
