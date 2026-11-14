import ArclightCore
import CoreGraphics
import Foundation

/// Creator tools for thumbnails: A/B variants, frames from video or motion scenes, and reference analysis.
extension MCPServer {
    func creatorTools() -> [Tool] {
        [
            Tool(
                name: "thumbnail_variants",
                description:
                    "Make A/B variants of a finished thumbnail artboard for YouTube Test & Compare (up to 3 thumbnails). Each variant is a copy placed to the right, named B, C…, that should change ONE thing. Either give variants [{name?, ops:[…]}] (ops as in thumbnail_apply, run on the copy), or auto: color | zoom | background with count.",
                schema: schema(
                    [
                        "thumbnail": prop("string", "Thumbnail id"),
                        "artboard": prop("string", "The artboard to vary (default: the first)"),
                        "variants": prop(
                            "array", "[{\"name\":\"B\",\"ops\":[{\"op\":\"set\",\"id\":\"title\",\"text\":\"I'M DONE\"}]}]",
                            extra: ["items": ["type": "object"]]),
                        "auto": prop("string", "Automatic: what each copy changes", extra: ["enum": ["color", "zoom", "background"]]),
                        "count": prop("integer", "With auto: how many copies (default 2)"),
                    ], required: ["thumbnail"])
            ) { [unowned self] a in
                let s = try requireStore()
                let p = try s.thumbnail(try a.str("thumbnail"))
                guard let base = p.artboard(a["artboard"]?.string) else { throw ToolError("no such artboard") }
                let made: (Thumbnail, [String])
                if let axis = a["auto"]?.string {
                    guard let ax = ThumbnailVariants.Axis(rawValue: axis) else { throw ToolError("auto must be color, zoom or background") }
                    let n = try SafeNumber.int(a["count"]?.double ?? 2, "count", in: 1...5)
                    made = try ThumbnailVariants.makeAuto(ax, count: n, of: base.id, in: p)
                } else {
                    let specs = try (a["variants"]?.array ?? []).map { v -> ThumbnailVariants.Spec in
                        guard let o = v.object else { throw ToolError("each variant is an object") }
                        return ThumbnailVariants.Spec(name: o["name"]?.string, ops: o["ops"]?.array ?? [])
                    }
                    guard !specs.isEmpty else { throw ToolError("give variants or auto") }
                    made = try ThumbnailVariants.make(specs, of: base.id, in: p)
                }
                let saved = try saveValidated(made.0, store: s, expectedRev: p.rev, summary: "variants of \(base.id)")
                return text(
                    thumbnailReport(saved, changed: made.1, store: s)
                        + "\nexport the set with export {thumbnail:\"\(p.id)\"}; check them side by side with thumbnail_render")
            },

            Tool(
                name: "frame_extract",
                description:
                    "Still frames for a thumbnail: from a video file (times in seconds, or best: the sharpest frames with the best faces), or a motion scene rendered at a time. Saved as image assets; with thumbnail (+ artboard) the first one is also placed as a new image layer filling the artboard (fit cover), at the bottom.",
                schema: schema(
                    [
                        "video": prop("string", "Video file path or an asset name (mov, mp4, m4v)"),
                        "scene": prop("string", "Instead of video: a motion scene id to render"),
                        "times": prop("array", "Seconds", extra: ["items": ["type": "number"]]),
                        "best": prop("integer", "Pick this many best frames (video only)"),
                        "thumbnail": prop("string", "Place the first frame in this thumbnail"),
                        "artboard": prop("string", "Artboard (default: the first)"),
                    ])
            ) { [unowned self] a in
                let s = try requireStore()
                var frames: [FrameExtractor.Frame] = []
                if let sid = a["scene"]?.string {
                    let scene = try s.scene(sid)
                    let times = a["times"]?.doubles ?? [scene.duration / 2]
                    let r = try renderer()
                    frames = try times.prefix(6).map {
                        try FrameExtractor.snapshot(scene: scene, time: $0, project: s.project, store: s, renderer: r)
                    }
                } else {
                    let v = try a.str("video")
                    let url = v.contains("/") ? URL(expandingPath: v) : s.assetsURL.appendingPathComponent(v)
                    guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("no video at \(url.path)") }
                    if let n = a["best"]?.double {
                        let count = try SafeNumber.int(n, "best", in: 1...6)
                        frames = try blocking { try await FrameExtractor.best(video: url, count: count, store: s) }
                    } else {
                        let times = a["times"]?.doubles ?? [0]
                        frames = try blocking { try await FrameExtractor.frames(video: url, times: Array(times.prefix(6)), store: s) }
                    }
                }
                var lines = frames.map {
                    "\($0.asset)  t=\(String(format: "%.2f", $0.time))s  \($0.width)x\($0.height)"
                        + ($0.score.map { "  score \(String(format: "%.2f", $0))" } ?? "")
                }
                if let pid = a["thumbnail"]?.string, let f = frames.first {
                    let p = try s.thumbnail(pid)
                    guard let ab = p.artboard(a["artboard"]?.string) else { throw ToolError("no such artboard") }
                    let id = SceneOps.uniqueId("frame", in: ab.asScene(thumbnail: p.id))
                    let op: JSONValue = [
                        "op": "add", "index": 0,
                        "node": [
                            "id": .string(id), "type": "image", "src": .string(f.asset),
                            "x": .number(Double(ab.width) / 2), "y": .number(Double(ab.height) / 2),
                            "width": .number(Double(ab.width)), "height": .number(Double(ab.height)), "fit": "cover",
                        ],
                    ]
                    let r = try ThumbnailOps.apply([op], to: p, artboard: ab.id)
                    let saved = try saveValidated(r.thumbnail, store: s, expectedRev: p.rev, summary: "frame \(f.asset)")
                    lines.append(thumbnailReport(saved, changed: r.changed, store: s))
                }
                return text(lines.joined(separator: "\n"))
            },

            Tool(
                name: "reference_add",
                description:
                    "Keep a reference thumbnail with a thumbnail page (never exported): a YouTube video URL or id (its public thumbnail is fetched), an image path, or an asset name. Then reference_analyze it.",
                schema: schema(
                    [
                        "thumbnail": prop("string", "Thumbnail id"),
                        "source": prop("string", "YouTube URL / id, image path, or asset name"),
                    ], required: ["thumbnail", "source"])
            ) { [unowned self] a in
                let s = try requireStore()
                let p = try s.thumbnail(try a.str("thumbnail"))
                let src = try a.str("source")
                let name: String
                if let yt = ReferenceAnalyzer.youtubeID(src) {
                    let data = try blocking { try await ReferenceAnalyzer.fetchYouTubeThumbnail(yt) }
                    name = try AssetWriter.writeImage(data, name: "ref-\(yt).jpg", to: s).src
                } else if src.contains("/") {
                    name = try s.importAsset(from: URL(expandingPath: src))
                } else {
                    guard FileManager.default.fileExists(atPath: s.assetsURL.appendingPathComponent(src).path) else {
                        throw ToolError("no asset \(src)")
                    }
                    name = src
                }
                let refs = (p.references ?? []).filter { $0 != name } + [name]
                let r = try ThumbnailOps.apply([["op": "thumbnail", "references": .array(refs.map { .string($0) })]], to: p)
                _ = try saveValidated(r.thumbnail, store: s, expectedRev: p.rev, summary: "reference \(name)")
                return text("reference \(name) added to \(p.id) (\(refs.count) total) — reference_analyze {asset:\"\(name)\"}")
            },

            Tool(
                name: "reference_analyze",
                description:
                    "Analyse a reference picture on this Mac: dominant colours, text and its size/position, faces, where the eye lands, layout notes — plus the picture itself. Use it to rebuild the STRUCTURE (composition, hierarchy, colour mood) with the user's own photos, theme and words; never copy someone else's artwork or text.",
                schema: schema(["asset": prop("string", "Asset name (or a path)")], required: ["asset"]), readOnly: true
            ) { [unowned self] a in
                let s = try requireStore()
                let v = try a.str("asset")
                let url = v.contains("/") ? URL(expandingPath: v) : s.assetsURL.appendingPathComponent(v)
                let img = try ImageData.load(url)
                let r = ReferenceAnalyzer.analyze(img)
                var blocks: [JSONValue] = []
                if let small = ImageData.resize(img, 480, max(1, 480 * img.height / max(img.width, 1))),
                    let jpg = ContactSheet.jpeg(small)
                {
                    blocks.append(["type": "image", "data": .string(jpg.base64EncodedString()), "mimeType": "image/jpeg"])
                }
                var lines = [
                    "\(v): \(r.width)x\(r.height), \(r.tone), contrast \(r.contrast):1",
                    "palette: " + zip(r.palette, r.shares).map { "\($0) \(Int($1 * 100))%" }.joined(separator: ", "),
                ]
                lines += r.layout.map { "- " + $0 }
                for t in r.text { lines.append("text “\(t.text ?? "")” at \(t.box)") }
                for f in r.faces { lines.append("face at \(f.box)") }
                lines.append("(boxes are [x, y, w, h] fractions; ×1280 / ×720 for a thumbnail artboard)")
                blocks.append(["type": "text", "text": .string(lines.joined(separator: "\n"))])
                return blocks
            },
        ]
    }
}
