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
                if times.isEmpty { times = [0.15, 0.4, 0.7, 0.98].map { ($0 * scene.duration * 100).rounded() / 100 } }
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
                    "Export scenes: mp4 (H.264), hevc, prores (ProRes 4444 .mov with transparency for overlays) or png (image sequence). Pass frame (seconds) for a single PNG still. Scene audio is mixed in. Returns file paths.",
                schema: schema([
                    "scenes": prop(
                        "array", "Scene ids; default all in project order", extra: ["items": ["type": "string"]]),
                    "format": prop("string", "Default mp4", extra: ["enum": ["mp4", "hevc", "prores", "png"]]),
                    "frame": prop("number", "Export a single PNG still at this time (seconds) instead of video"),
                    "scale": prop("number", "Resolution scale, default 1 (2 = 4K from a 1080p canvas)"),
                    "fps": prop("number", "Override frame rate"),
                    "transparent": prop(
                        "boolean", "ProRes/PNG: transparent background (ProRes default true, PNG default false)"),
                    "out_dir": prop("string", "Default <project>/exports"),
                ])
            ) { [unowned self] a in
                let s = try requireStore()
                let ids = a["scenes"]?.array?.compactMap(\.string) ?? s.project.scenes
                guard !ids.isEmpty else { throw ToolError("nothing to export") }
                // Scene ids become file names in out_dir.
                for id in ids { try SafeName.component(id, what: "scene id") }
                var o = ExportOptions()
                if let f = a["format"]?.string {
                    guard let ff = ExportFormat(rawValue: f) else {
                        throw ToolError("format must be mp4, hevc, prores or png")
                    }; o.format = ff
                }
                o.scale = try SafeNumber.positive(a["scale"]?.double ?? 1, "scale", max: SafeNumber.maxScale)
                o.fps = try a["fps"]?.double.map { try SafeNumber.positive($0, "fps", max: SafeNumber.maxFPS) }
                o.transparent = a["transparent"]?.bool
                let dir = a["out_dir"]?.string.map(URL.init(expandingPath:)) ?? s.url.appendingPathComponent("exports")
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
                    "Copy an image file into the project's assets/ folder. Returns the name to use as an image node's src.",
                schema: schema(
                    ["path": prop("string", "Source file path"), "name": prop("string", "Optional new file name")],
                    required: ["path"])
            ) { [unowned self] a in
                let s = try requireStore()
                let src = URL(expandingPath: try a.str("path"))
                guard FileManager.default.fileExists(atPath: src.path) else {
                    throw ToolError("no file at \(src.path)")
                }
                let name = try a["name"]?.string.map { try SafeName.fileName($0) }
                return text("src: " + (try s.importAsset(from: src, name: name)))
            },
        ]
    }
}
