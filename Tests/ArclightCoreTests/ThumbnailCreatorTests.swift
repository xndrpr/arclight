import CoreGraphics
import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightMCP

/// Phase 5: thumbnail templates, A/B variants, frames from video / scenes, references.
@Suite(.serialized) struct ThumbnailCreatorTests {
    @Test func everyThumbnailTemplateDecodesValidatesAndKeepsTheTimestampCornerClear() throws {
        let thumbnails = BuiltInTemplates.all.filter(\.isThumbnail)
        #expect(thumbnails.count == ThumbnailTemplates.sources.count)  // none silently failed to decode
        #expect(thumbnails.count >= 6)
        let tp = try TempProject("tpl")
        defer { tp.remove() }
        for t in thumbnails {
            let a = try Templates.instantiateArtboard(t, params: [:], artboardId: "a", store: tp.store)
            #expect(a.size == [1280, 720], "\(t.id)")
            let issues = Validator.validate(a.asScene(thumbnail: "p"))
            #expect(issues.isEmpty, "\(t.id): \(issues)")
            // Image params fall back to the placeholder, which exists.
            for n in a.nodes where n.type == "image" {
                #expect(n.props["src"] == .value(.string(Templates.placeholderPhoto)), "\(t.id)")
            }
        }
        #expect(
            FileManager.default.fileExists(
                atPath: tp.store.assetsURL.appendingPathComponent(Templates.placeholderPhoto).path))
        // Scene templates stay scene templates.
        #expect(BuiltInTemplates.all.filter { !$0.isThumbnail }.map(\.id).contains("title"))
    }

    @Test(.requiresMetal) func templatesRenderAndInstantiateOverMCP() throws {
        let tp = try TempProject("tpl-mcp")
        defer { tp.remove() }
        let s = MCPServer(projectPath: tp.url.path)
        func run(_ n: String, _ a: [String: JSONValue]) throws -> String {
            try s.tools.first { $0.name == n }!.run(a).compactMap { $0.object?["text"]?.string }.joined()
        }
        #expect(try run("template_list", ["kind": "thumbnail"]).contains("thumb-face-words (thumbnail)"))
        #expect(!(try run("template_list", ["kind": "thumbnail"])).contains("lower-third"))
        let out = try run(
            "template_instantiate",
            ["template": "thumb-face-words", "thumbnail": "ep", "params": ["line1": "NEW", "line2": "LIFE"]])
        #expect(out.contains("saved thumbnail ep rev 1"))
        _ = try run("template_instantiate", ["template": "thumb-minimal", "thumbnail": "ep"])
        let p = try ProjectStore(url: tp.url).thumbnail("ep")
        #expect(p.artboards.map(\.id) == ["face-words", "minimal"])
        #expect(p.artboards[1].x > p.artboards[0].x)
        #expect(p.artboards[0].nodes.first { $0.id == "line1" }?.props["text"] == .value("NEW"))
        let r = try s.tools.first { $0.name == "thumbnail_render" }!.run(["thumbnail": "ep", "scale": 0.2])
        #expect(r.first?.object?["type"]?.string == "image")
    }

    @Test func variantsChangeOnlyWhatTheyShould() throws {
        var a = Artboard(id: "a", name: "A")
        a.background = .value("$bg")
        a.nodes = [
            Node(id: "title", type: "text", props: ["text": .value("HI"), "color": .value("$accent")]),
            Node(id: "body", type: "text", props: ["text": .value("x"), "color": .value("$fg")]),
            Node(id: "pic", type: "image", props: ["src": .value("p.png")]),
        ]
        let p = ArclightCore.Thumbnail(id: "p", artboards: [a])
        let (c, ids) = try ThumbnailVariants.makeAuto(.color, count: 2, of: "a", in: p)
        #expect(ids == ["b", "c"])
        #expect(c.artboards.map(\.name) == ["A", "B", "C"])
        let b = try #require(c.artboard("b"))
        #expect(b.nodes[0].props["color"] != a.nodes[0].props["color"])  // the accent layer changed
        #expect(b.nodes[1] == a.nodes[1] && b.nodes[2] == a.nodes[2])  // nothing else did
        #expect(b.background == a.background)
        let (z, _) = try ThumbnailVariants.makeAuto(.zoom, count: 1, of: "a", in: p)
        #expect(z.artboard("b")?.nodes[2].props["scale"] == .value(1.15))
        #expect(z.artboard("b")?.nodes[0] == a.nodes[0])
        let (bg, _) = try ThumbnailVariants.makeAuto(.background, count: 1, of: "a", in: p)
        #expect(bg.artboard("b")?.background != a.background && bg.artboard("b")?.nodes == a.nodes)
        let (m, mids) = try ThumbnailVariants.make(
            [.init(name: "Words", ops: [["op": "set", "id": "title", "text": "BYE"]])], of: "a", in: p)
        #expect(m.artboard(mids[0])?.name == "Words")
        #expect(m.artboard(mids[0])?.nodes[0].props["text"] == .value("BYE"))
        #expect(m.artboard("a")?.nodes[0].props["text"] == .value("HI"))
        // Names in any script make valid ids.
        let (u, uids) = try ThumbnailVariants.make(
            [.init(name: "B · Дверь", ops: []), .init(name: "Пирс", ops: [])], of: "a", in: p)
        #expect(uids == ["b", "variant"])
        #expect(u.artboard("variant")?.name == "Пирс")
    }

    @Test(.requiresMetal) func framesFromAVideoAndFromAScene() async throws {
        let tp = try TempProject("frames")
        defer { tp.remove() }
        // A 2-second clip made by the exporter: a white box moving across black.
        var s = ArclightCore.Scene(id: "clip", duration: 2)
        s.size = [320, 180]; s.fps = 10
        s.nodes = [
            Node(
                id: "box", type: "shape",
                props: [
                    "shape": .value("rect"), "width": .value(40), "height": .value(40), "y": .value(90),
                    "fill": .value("#FFFFFF"),
                    "x": .keys([Keyframe(t: 0, v: 20), Keyframe(t: 2, v: 300)]),
                ])
        ]
        try tp.store.save(scene: s)
        let video = tp.url.appendingPathComponent("clip.mp4")
        _ = try Exporter(renderer: try Renderer()).export(
            scene: s, project: tp.store.project, assets: tp.store.assetsURL, to: video, options: ExportOptions())
        let frames = try await FrameExtractor.frames(video: video, times: [0.5, 1.5], store: tp.store)
        #expect(frames.map(\.width) == [320, 320])
        #expect(frames[0].asset != frames[1].asset)
        let best = try await FrameExtractor.best(video: video, count: 2, samples: 8, store: tp.store)
        #expect(best.count == 2 && abs(best[0].time - best[1].time) >= 1)
        let snap = try FrameExtractor.snapshot(
            scene: s, time: 1, project: tp.store.project, store: tp.store, renderer: try Renderer())
        #expect(snap.width == 320 && snap.asset.hasPrefix("scene-clip"))

        // Over MCP, a frame lands as the bottom layer of an artboard, filling it.
        try tp.store.save(thumbnail: ArclightCore.Thumbnail(id: "p", artboards: [Artboard(id: "a")]))
        let server = MCPServer(projectPath: tp.url.path)
        _ = try server.tools.first { $0.name == "frame_extract" }!.run([
            "video": .string(video.path), "times": [1], "thumbnail": "p",
        ])
        let a = try #require(try ProjectStore(url: tp.url).thumbnail("p").artboards.first)
        #expect(a.nodes.first?.type == "image" && a.nodes.first?.props["fit"] == .value("cover"))
    }

    @Test func youtubeIdsAndReferenceAnalysis() throws {
        #expect(ReferenceAnalyzer.youtubeID("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=10") == "dQw4w9WgXcQ")
        #expect(ReferenceAnalyzer.youtubeID("https://youtu.be/dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(ReferenceAnalyzer.youtubeID("https://youtube.com/shorts/abcdefghijk") == "abcdefghijk")
        #expect(ReferenceAnalyzer.youtubeID("dQw4w9WgXcQ") == "dQw4w9WgXcQ")
        #expect(ReferenceAnalyzer.youtubeID("https://example.com/watch?v=x") == nil)

        // Left half dark blue, right half yellow: two dominant colours, roughly half each.
        let ctx = try #require(ImageData.context(320, 180))
        ctx.setFillColor(CGColor(srgbRed: 0.05, green: 0.1, blue: 0.3, alpha: 1));
        ctx.fill(CGRect(x: 0, y: 0, width: 160, height: 180))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0.85, blue: 0.1, alpha: 1));
        ctx.fill(CGRect(x: 160, y: 0, width: 160, height: 180))
        let r = ReferenceAnalyzer.analyze(try #require(ctx.makeImage()))
        #expect(r.palette.count >= 2)
        #expect(r.shares.prefix(2).allSatisfy { $0 > 0.35 })
        #expect(r.contrast > 5)
        #expect(r.layout.contains("no text"))
    }
}
