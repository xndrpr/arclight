import ArclightCore
import Foundation

extension MCPServer {
    func outputTools() -> [Tool] {
        [
            Tool(
                name: "render_frames",
                description:
                    "Render frames of a scene into one labelled contact-sheet image to check your work visually. Keep scale low (0.25) to save tokens.",
                schema: schema(
                    [
                        "scene": prop("string", "Scene id"),
                        "times": prop(
                            "array", "Seconds; default 4 frames spread across the scene",
                            extra: ["items": ["type": "number"]]),
                        "scale": prop("number", "Per-frame scale of the canvas, default 0.25"),
                        "save": prop("string", "Optional path to also save the sheet as PNG"),
                    ], required: ["scene"]), readOnly: true
            ) { [unowned self] a in
                let s = try requireStore()
                let scene = try s.scene(try a.str("scene"))
                var times = a["times"]?.doubles ?? []
                if times.isEmpty { times = [0.15, 0.4, 0.7, 0.98].map { ($0 * scene.duration).rounded(places: 2) } }
                times = Array(times.prefix(9))
                let scale = min(max(a["scale"]?.double ?? 0.25, 0.05), 1)
                let img = try ContactSheet.render(
                    renderer: try renderer(), scene: scene, project: s.project, assets: s.assetsURL,
                    times: times, scale: scale)
                if let path = a["save"]?.string { try ImageFile.writePNG(img, to: URL(expandingPath: path)) }
                guard let jpg = ContactSheet.jpeg(img) else { throw ToolError("encode failed") }
                return [
                    ["type": "image", "data": .string(jpg.base64EncodedString()), "mimeType": "image/jpeg"],
                    [
                        "type": "text",
                        "text": .string(
                            "\(scene.id) rev \(scene.rev) at t=\(times.map { String(format: "%g", $0) }.joined(separator: ", "))"
                        ),
                    ],
                ]
            },

            Tool(
                name: "export",
                description:
                    "Export scenes: mp4 (H.264), hevc, prores (ProRes 4444 .mov with transparency for overlays) or png (image sequence). Pass frame (seconds) for a single PNG still. Scene audio is mixed in. join:true plays the scenes one after another in a single file named after the project (the user orders scenes by dragging them in the editor's Scenes list; project order is the default). For a thumbnail page pass thumbnail (and optionally artboards): format png, jpg or youtube (1280x720 JPG under YouTube's 2 MB limit; the default). Returns file paths.",
                schema: schema([
                    "scenes": prop(
                        "array", "Scene ids; default all in project order", extra: ["items": ["type": "string"]]),
                    "thumbnail": prop("string", "Export this thumbnail page's artboards instead of scenes"),
                    "artboards": prop(
                        "array", "With thumbnail: artboard ids, default all", extra: ["items": ["type": "string"]]),
                    "quality": prop("number", "jpg quality 0-1 (default: best that fits 2 MB for youtube, else 0.92)"),
                    "format": prop(
                        "string", "Default mp4 (scenes) or youtube (thumbnails)",
                        extra: ["enum": ["mp4", "hevc", "prores", "png", "jpg", "youtube"]]),
                    "frame": prop("number", "Export a single PNG still at this time (seconds) instead of video"),
                    "scale": prop("number", "Resolution scale, default 1 (2 = 4K from a 1080p canvas)"),
                    "fps": prop("number", "Override frame rate"),
                    "transparent": prop(
                        "boolean", "ProRes/PNG: transparent background (ProRes default true, PNG default false)"),
                    "out_dir": prop("string", "Default <project>/exports"),
                    "join": prop("boolean", "One file with all the scenes back to back, in the order given"),
                ])
            ) { [unowned self] a in
                let s = try requireStore()
                if let pid = a["thumbnail"]?.string { return try exportThumbnail(pid, a, store: s) }
                let ids = a["scenes"]?.array?.compactMap(\.string) ?? s.orderedScenes.map(\.id)
                guard !ids.isEmpty else { throw ToolError("nothing to export") }
                // Scene ids become file names in out_dir.
                for id in ids { try SafeName.component(id, what: "scene id") }
                var o = ExportOptions()
                if let f = a["format"]?.string {
                    guard let ff = ExportFormat(rawValue: f) else {
                        throw ToolError("format must be mp4, hevc, prores or png (jpg and youtube are for thumbnails)")
                    }; o.format = ff
                }
                o.scale = try SafeNumber.positive(a["scale"]?.double ?? 1, "scale", max: SafeNumber.maxScale)
                o.fps = try a["fps"]?.double.map { try SafeNumber.positive($0, "fps", max: SafeNumber.maxFPS) }
                o.transparent = a["transparent"]?.bool
                let dir =
                    a["out_dir"]?.string.map(URL.init(expandingPath:))
                    ?? s.url.appendingPathComponent(ProjectLayout.exports)
                let exporter = Exporter(renderer: try renderer())
                var lines: [String] = []
                if let t = a["frame"]?.double {
                    for id in ids {
                        let scene = try s.scene(id)
                        let u = try exporter.exportStill(
                            scene: scene, project: s.project, assets: s.assetsURL, time: t,
                            to: dir.appendingPathComponent("\(id)@\(String(format: "%g", t))s.png"),
                            scale: o.scale, transparent: o.transparent ?? false)
                        lines.append(u.path)
                    }
                    return text(lines.joined(separator: "\n"))
                }
                if a["join"]?.bool == true {
                    let r = try exporter.export(
                        scenes: try ids.map { try s.scene($0) }, project: s.project, assets: s.assetsURL,
                        to: dir.appendingPathComponent("\(Exporter.joinedName(s.project.name)).\(o.format.ext)"),
                        options: o)
                    return text(
                        "\(r.url.path)  \(r.width)x\(r.height)@\(String(format: "%g", r.fps))  \(r.frames) frames  \(ids.count) scenes  \(String(format: "%.1f", r.seconds))s"
                    )
                }
                for id in ids {
                    let scene = try s.scene(id)
                    let r = try exporter.export(
                        scene: scene, project: s.project, assets: s.assetsURL,
                        to: dir.appendingPathComponent("\(id).\(o.format.ext)"), options: o)
                    lines.append(
                        "\(r.url.path)  \(r.width)x\(r.height)@\(String(format: "%g", r.fps))  \(r.frames) frames  \(String(format: "%.1f", r.seconds))s"
                    )
                }
                return text(lines.joined(separator: "\n"))
            },

            Tool(
                name: "asset_import",
                description:
                    "Copy a file (image, sound, 3D model) into the project's assets/ folder. Returns the name to use as a layer's src. For a model it also says its triangles and its animation clips (a .glb/.gltf with bones, shape keys or moving parts plays on a model layer). A .blend is exported to .glb through the user's Blender when it is installed (animation included). Run it again on an asset already in assets/ to see its clips.",
                schema: schema(
                    ["path": prop("string", "Source file path"), "name": prop("string", "Optional new file name")],
                    required: ["path"])
            ) { [unowned self] a in
                let s = try requireStore()
                var src = URL(expandingPath: try a.str("path"))
                // A bare name already in assets/ (to see a model's clips again).
                let inAssets = s.assetsURL.appendingPathComponent(try a.str("path"))
                if !FileManager.default.fileExists(atPath: src.path), try !a.str("path").contains("/"),
                    FileManager.default.fileExists(atPath: inAssets.path)
                {
                    src = inAssets
                }
                guard FileManager.default.fileExists(atPath: src.path) else {
                    throw ToolError("no file at \(src.path)")
                }
                var name = try a["name"]?.string.map { try SafeName.fileName($0) }
                var file = src
                if src.pathExtension.lowercased() == "blend" {
                    // Blender files go through the user's Blender to a .glb with the animation.
                    let base =
                        (name.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
                            ?? src.deletingPathExtension().lastPathComponent)
                    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
                        "blend-\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: tmp) }
                    file = try BlendConverter.convert(src, to: tmp.appendingPathComponent("\(base).glb"))
                    name = try SafeName.fileName("\(base).glb")
                    let n = try s.importAsset(from: file, name: name)
                    let info = (try? Mesh.load(s.assetsURL.appendingPathComponent(n)))?.summary ?? ""
                    return text("src: \(n) (exported from \(src.lastPathComponent) with Blender)\n\(info)")
                }
                let n = try s.importAsset(from: file, name: name)
                if AudioFiles.readable.contains(src.pathExtension.lowercased()),
                    let d = try? AudioDescriptors.measure(s.assetsURL.appendingPathComponent(n))
                {
                    return text(
                        "src: \(n) (\(Format.number(d.duration.rounded(places: 2)))s)\nmeasured: \(d.line)\nPlace it with scene_apply {\"op\":\"sound\",\"src\":\"\(n)\",\"offset\":t}; audio_analyze {src, image:true} shows more.")
                }
                guard Mesh.extensions.contains(src.pathExtension.lowercased()) else { return text("src: " + n) }
                let mesh = try Mesh.load(s.assetsURL.appendingPathComponent(n))
                return text("src: \(n)\n\(mesh.summary)")
            },
        ]
    }

    /// `export` for a thumbnail page: one image per artboard, named `<thumbnail>_<artboard>.<ext>`.
    func exportThumbnail(_ id: String, _ a: [String: JSONValue], store s: ProjectStore) throws -> [JSONValue] {
        let p = try s.thumbnail(id)
        let ids = a["artboards"]?.array?.compactMap(\.string) ?? p.artboards.map(\.id)
        guard !ids.isEmpty else { throw ToolError("the thumbnail has no artboards") }
        let format = a["format"]?.string ?? "youtube"
        var o: StillExporter.Options
        switch format {
        case "youtube": o = .youtube
        case "jpg": o = StillExporter.Options(); o.format = .jpg
        case "png": o = StillExporter.Options(); o.format = .png
        default: throw ToolError("thumbnails export as png, jpg or youtube")
        }
        if let q = a["quality"]?.double {
            guard q > 0, q <= 1 else { throw ToolError("quality must be in 0…1") }
            o.quality = q
        }
        o.transparent = a["transparent"]?.bool ?? false
        let userScale = try a["scale"]?.double.map { try SafeNumber.positive($0, "scale", max: SafeNumber.maxScale) }
        let dir =
            a["out_dir"]?.string.map(URL.init(expandingPath:)) ?? s.url.appendingPathComponent(ProjectLayout.exports)
        let ex = StillExporter(renderer: try renderer())
        var lines: [String] = []
        for aid in ids {
            let ab = p.artboards[try p.index(of: aid)]
            o.scale = userScale ?? (format == "youtube" ? StillExporter.youtubeScale(for: ab) : 1)
            let name = try SafeName.component("\(p.id)_\(ab.id).\(o.format.ext)", what: "file name")
            let r = try ex.export(
                artboard: ab, thumbnail: p, project: s.project, assets: s.assetsURL,
                to: dir.appendingPathComponent(name), options: o)
            var line = "\(r.url.path)  \(r.width)x\(r.height)  \(Format.bytes(r.bytes))"
            if let q = r.quality { line += "  q\(String(format: "%.2f", q))" }
            if r.overLimit {
                line += "  WARNING: over YouTube's 2 MB limit — simplify the image or pass a lower quality"
            }
            lines.append(line)
        }
        return text(lines.joined(separator: "\n"))
    }
}
