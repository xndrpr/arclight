import Foundation
import ImageIO
import Testing

@testable import ArclightCore
@testable import ArclightMCP

/// The thumbnail tools end to end, in-process: create → apply → render → export → history, as an agent uses them.
@Suite(.requiresMetal) struct ThumbnailMCPTests {
    private func run(_ s: MCPServer, _ name: String, _ args: [String: JSONValue]) throws -> [JSONValue] {
        guard let tool = s.tools.first(where: { $0.name == name }) else { throw ToolError("no tool \(name)") }
        return try tool.run(args)
    }

    private func text(_ out: [JSONValue]) -> String {
        out.compactMap { $0.object?["text"]?.string }.joined(separator: "\n")
    }

    private func server() throws -> (MCPServer, TempProject) {
        let tp = try TempProject("thumbnail-mcp")
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
        let created = text(try run(s, "thumbnail_create", thumb))
        #expect(created.contains("saved thumbnail ep12 rev 1"))
        #expect(created.contains("artboard shorts \"\"") == false)
        let p = try #require(tp.store.thumbnails["ep12"] ?? (try? ProjectStore(url: tp.url))?.thumbnails["ep12"])
        #expect(p.artboards.map(\.id) == ["a", "shorts"])
        #expect(p.artboards[1].size == [1080, 1920])
        #expect(p.artboards[1].x == 1280 + 120)  // laid out left to right

        // Variant B: duplicate and change one thing, in one atomic call.
        let applied = text(
            try run(
                s, "thumbnail_apply",
                [
                    "thumbnail": "ep12",
                    "ops": [
                        ["op": "artboard_duplicate", "id": "a", "as": "b", "name": "B"],
                        ["op": "set", "artboard": "b", "id": "title", "text": "I'M DONE"],
                    ],
                ]))
        #expect(applied.contains("rev 2"))
        #expect(applied.contains("b/title"))
        let store = try ProjectStore(url: tp.url)
        let b = try #require(store.thumbnails["ep12"]?.artboard("b"))
        #expect(b.nodes.first?.props["text"] == .value("I'M DONE"))
        #expect(store.thumbnails["ep12"]?.artboard("a")?.nodes.first?.props["text"] == .value("I QUIT"))

        // A text layer's font size is a number, not an artboard size preset.
        let sized = text(
            try run(s, "thumbnail_apply", ["thumbnail": "ep12", "ops": [["op": "set", "id": "title", "size": 84]]]))
        #expect(sized.contains("size=84"))
        _ = try run(s, "thumbnail_apply", ["thumbnail": "ep12", "ops": [["op": "set", "id": "title", "size": 160]]])
        // Bad layer props are refused and nothing is saved.
        let bad = try? run(
            s, "thumbnail_apply", ["thumbnail": "ep12", "ops": [["op": "set", "id": "title", "colour": "#fff"]]])
        #expect(bad == nil)
        #expect(try ProjectStore(url: tp.url).thumbnails["ep12"]?.rev == 4)

        // Render: one image block plus a label line, with feed mock-ups.
        let r = try run(s, "thumbnail_render", ["thumbnail": "ep12", "feed": true, "scale": 0.2])
        #expect(r.first?.object?["type"]?.string == "image")
        #expect(text(r).contains("a feed"))

        // Export: YouTube preset → JPGs under 2 MB, 1280×720 and the Shorts cover turned upright (720×1280).
        let out = text(try run(s, "export", ["thumbnail": "ep12", "artboards": ["a", "shorts"]]))
        let files = Self.files(out)
        #expect(files.count == 2)
        for f in files {
            let size = try #require(try FileManager.default.attributesOfItem(atPath: f)[.size] as? Int)
            #expect(size < StillExporter.youtubeMaxBytes)
            let px = try Self.pixels(f)
            if f.hasSuffix("ep12_a.jpg") { #expect(px == [1280, 720]) }
            if f.hasSuffix("ep12_shorts.jpg") { #expect(px == [720, 1280]) }
        }
        let png = text(try run(s, "export", ["thumbnail": "ep12", "artboards": ["b"], "format": "png", "scale": 0.5]))
        #expect(png.contains("ep12_b.png") && png.contains("640x360"))
    }

    private static func files(_ out: String) -> [String] {
        out.split(separator: "\n").map { String($0.split(separator: " ").first ?? "") }
    }

    /// [width, height] of the image file at `path`.
    private static func pixels(_ path: String) throws -> [Int] {
        let src = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        return [props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0]
    }

    /// Every format keeps each artboard's own aspect and orientation: landscape, portrait, square and 4:5 alike.
    @Test func exportKeepsEachArtboardsShape() throws {
        let (s, tp) = try server()
        defer { tp.remove() }
        let boards: [(id: String, preset: String, youtube: [Int], own: [Int])] = [
            ("wide", "youtube-hd", [1280, 720], [1920, 1080]),
            ("tall", "shorts", [720, 1280], [1080, 1920]),
            ("square", "square", [720, 720], [1080, 1080]),
            ("portrait", "portrait", [720, 900], [1080, 1350]),
        ]
        let artboards = boards.map { JSONValue.object(["id": .string($0.id), "size": .string($0.preset)]) }
        _ = try run(s, "thumbnail_create", ["id": "shapes", "artboards": .array(artboards)])
        for format in ["youtube", "jpg", "png"] {
            let dir = tp.url.appendingPathComponent("exports/\(format)").path
            let out = text(
                try run(s, "export", ["thumbnail": "shapes", "format": .string(format), "out_dir": .string(dir)]))
            let files = Self.files(out)
            #expect(files.count == boards.count)
            for b in boards {
                let f = try #require(files.first { $0.hasSuffix("shapes_\(b.id).\(format == "png" ? "png" : "jpg")") })
                let px = try Self.pixels(f)
                #expect(px == (format == "youtube" ? b.youtube : b.own), "\(format) \(b.id)")
                #expect(out.contains("\(px[0])x\(px[1])"))  // the reported size is the written one
                #expect(abs(Double(px[0]) / Double(px[1]) - Double(b.own[0]) / Double(b.own[1])) < 0.005)
            }
        }
    }

    @Test func outlineHistoryThemeAndDelete() throws {
        let (s, tp) = try server()
        defer { tp.remove() }
        _ = try run(s, "thumbnail_create", thumb)
        let outline = text(try run(s, "thumbnail_get", ["thumbnail": "ep12"]))
        #expect(outline.contains("artboard a \"A\"  1280x720"))
        #expect(outline.contains("title text"))
        let json = text(try run(s, "thumbnail_get", ["thumbnail": "ep12", "artboard": "a", "ids": ["title"]]))
        #expect(json.contains("\"I QUIT\""))

        _ = try run(
            s, "thumbnail_apply",
            [
                "thumbnail": "ep12",
                "ops": [["op": "thumbnail", "theme": ["detached": true, "tokens": ["accent": "#FF0044"]]]],
            ])
        let st = try ProjectStore(url: tp.url)
        #expect(st.project.theme(for: try st.thumbnail("ep12"))["accent"] == "#FF0044")
        #expect(text(try run(s, "project_get", [:])).contains("thumbnail ep12"))

        let hist = text(try run(s, "history", ["thumbnail": "ep12"]))
        #expect(hist.contains("rev 1") && hist.contains("rev 2"))
        _ = try run(s, "history", ["thumbnail": "ep12", "revert_to": 1])
        #expect(try ProjectStore(url: tp.url).thumbnail("ep12").theme == .project)

        #expect(text(try run(s, "thumbnail_list", [:])).contains("ep12"))
        _ = try run(s, "thumbnail_delete", ["thumbnail": "ep12"])
        #expect(try ProjectStore(url: tp.url).thumbnails.isEmpty)
    }

    @Test func thumbnailOnlyProjectAndGuide() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-pv-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: parent) }
        let s = MCPServer(projectPath: nil)
        let path = parent.appendingPathComponent("Thumbs.arclight").path
        _ = try run(s, "project_create", ["path": .string(path), "start": "thumbnail"])
        _ = try run(s, "thumbnail_create", ["id": "t"])
        let st = try ProjectStore(url: URL(fileURLWithPath: path))
        #expect(st.project.workspace == "thumbnail")
        #expect(st.scenes.isEmpty)
        #expect(st.thumbnails["t"]?.artboards.first?.size == [1280, 720])
        #expect(text(try run(s, "guide", ["topic": "thumbnails"])).contains("artboard_duplicate"))
        #expect(Guide.instructions.contains("thumbnail_create"))
        #expect((try? run(s, "thumbnail_create", ["id": "t"])) == nil)  // exists → thumbnail_apply or overwrite
        #expect((try? run(s, "thumbnail_create", ["id": "bad/id"])) == nil)
        #expect((try? run(s, "thumbnail_create", ["id": "u", "artboards": [["id": "x", "size": "huge"]]])) == nil)
    }
}
