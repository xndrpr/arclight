import ArclightCore
import CoreGraphics
import Foundation

/// Preview pages (YouTube thumbnails, Shorts covers, A/B variants): artboards whose layers are scene nodes.
extension MCPServer {
    /// Validates every artboard as the scene it renders as, then saves.
    func saveValidated(_ p: Preview, store s: ProjectStore, expectedRev: Int?, summary: String) throws -> Preview {
        var problems: [String] = []
        let expr = try renderer().evaluator.expr
        for a in p.artboards {
            problems += Validator.validate(a.asScene(preview: p.id), expr: expr).map { "\(a.id): \($0)" }
        }
        if !problems.isEmpty {
            throw ToolError("not saved — fix these:\n" + problems.map { "- \($0)" }.joined(separator: "\n"))
        }
        return try s.save(preview: p, expectedRev: expectedRev, summary: summary, source: .ai)
    }

    func previewOutline(_ p: Preview, store s: ProjectStore, only: Set<String>? = nil) -> String {
        var out = "preview \(p.id)\(p.name.map { " \"\($0)\"" } ?? "")  rev \(p.rev)  \(p.artboards.count) artboard(s)"
        switch p.theme {
        case .project: out += "  theme: project"
        case .detached(let t): out += "  theme: detached " + compactJSON(t)
        }
        out += "\n"
        let project = s.project.rendering(p)
        for a in p.artboards where only?.contains(a.id) ?? true {
            out +=
                "artboard \(a.id)\(a.name.map { " \"\($0)\"" } ?? "")  \(a.width)x\(a.height) at (\(Format.number(a.x)), \(Format.number(a.y)))\n"
            // Reuse the scene outline for layers; drop its header line (the artboard line above replaces it).
            let body = Outline.scene(a.asScene(preview: p.id), project: project).split(
                separator: "\n", omittingEmptySubsequences: false
            ).dropFirst()
            out += body.map { "  " + $0 }.joined(separator: "\n") + "\n"
        }
        return out
    }

    func previewReport(_ p: Preview, changed: [String], store s: ProjectStore) -> String {
        var lines = ["saved preview \(p.id) rev \(p.rev) (\(p.artboards.map(\.id).joined(separator: ", ")))"]
        for c in changed.prefix(12) {
            let parts = c.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, let n = p.artboard(parts[0])?.nodes.first(where: { $0.id == parts[1] }) {
                lines.append("  \(parts[0])/" + Outline.node(n))
            } else if let a = p.artboard(c) {
                lines.append("  artboard \(a.id) \(a.width)x\(a.height) \(a.nodes.count) layers")
            } else {
                lines.append("  \(c) (removed)")
            }
        }
        if changed.count > 12 { lines.append("  … \(changed.count - 12) more") }
        return lines.joined(separator: "\n")
    }

    static func artboardSize(_ v: JSONValue?) throws -> [Int]? {
        guard let v else { return nil }
        if case .string(let preset) = v {
            guard let z = ArtboardPresets.size(preset) else {
                throw ToolError("unknown size preset '\(preset)' — \(ArtboardPresets.names.joined(separator: ", "))")
            }
            return z
        }
        return try canvasSize(v)
    }

    func previewTools() -> [Tool] {
        [
            Tool(
                name: "preview_list",
                description: "List the project's preview pages (thumbnails) and their artboards.",
                schema: schema([:]), readOnly: true
            ) { [unowned self] _ in
                let s = try requireStore()
                if s.orderedPreviews.isEmpty { return text("no previews yet — preview_create") }
                return text(
                    s.orderedPreviews.map { p in
                        "preview \(p.id)\(p.name.map { " \"\($0)\"" } ?? "")  rev \(p.rev)  "
                            + p.artboards.map { "\($0.id) \($0.width)x\($0.height) (\($0.nodes.count) layers)" }
                            .joined(separator: " · ")
                    }.joined(separator: "\n"))
            },

            Tool(
                name: "preview_create",
                description:
                    "Create (or overwrite with overwrite:true) a preview page: one or more artboards (YouTube thumbnail 1280x720 by default) with ALL their layers in one call. Layers are the same node JSON as scenes (see guide). Use theme tokens so the brand stays in sync with the project.",
                schema: schema(
                    [
                        "id": prop("string", "Preview id (file name), e.g. \"ep12-thumb\""),
                        "name": prop("string", "Display name"),
                        "artboards": prop(
                            "array",
                            "Artboards: {id, name, size ([w,h] or a preset: \(ArtboardPresets.names.joined(separator: ", "))), x, y, background, post, nodes:[...]}. Default: one 1280x720 artboard \"a\". x/y default to a row, left to right.",
                            extra: ["items": ["type": "object"]]),
                        "theme": prop(
                            "object",
                            "Omit to share the project theme (default). {\"detached\":true,\"tokens\":{...}} gives this preview its own tokens on top of the project's."
                        ),
                        "copy_from": prop("string", "Existing preview id to copy as the starting point"),
                        "overwrite": prop("boolean", "Replace an existing preview with this id"),
                    ], required: ["id"])
            ) { [unowned self] a in
                let s = try requireStore()
                let id = try SafeName.id(try a.str("id"))
                if s.previews[id] != nil && a["overwrite"]?.bool != true {
                    throw ToolError("preview '\(id)' exists — use preview_apply, or overwrite:true")
                }
                var p = Preview(id: id)
                if let from = a["copy_from"]?.string { p = try s.preview(from); p.id = id }
                p.rev = s.previews[id]?.rev ?? 0
                if let n = a["name"]?.string { p.name = n }
                if let t = a["theme"] { p.theme = try t.decoded(as: ThemeLink.self) }
                if let list = a["artboards"]?.array {
                    p.artboards = []
                    for (i, v) in list.enumerated() {
                        guard var o = v.object else { throw ToolError("artboard \(i) must be an object") }
                        let aid = try SafeName.id(o["id"]?.string ?? p.uniqueArtboardId("a"), what: "artboard id")
                        guard p.artboard(aid) == nil else { throw ToolError("duplicate artboard id '\(aid)'") }
                        var ab = Artboard(id: aid)
                        ab.background = .value("$bg")
                        (ab.x, ab.y) = p.nextArtboardOrigin()
                        if let z = try MCPServer.artboardSize(o["size"]) { ab.size = z }
                        o["size"] = nil
                        do {
                            try PreviewOps.setFields(o, on: &ab)
                            ab.nodes = try (o["nodes"]?.array ?? []).enumerated().map { k, n in
                                do { return try SceneOps.decodeNode(n) } catch { throw ToolError("node \(k): \(error)") }
                            }
                        } catch let e as ToolError { throw ToolError("artboard \(aid): \(e)") } catch {
                            throw ToolError("artboard \(aid): \(error)")
                        }
                        p.artboards.append(ab)
                    }
                }
                if p.artboards.isEmpty {
                    var ab = Artboard(id: "a", name: "A"); ab.background = .value("$bg"); p.artboards = [ab]
                }
                let saved = try saveValidated(p, store: s, expectedRev: nil, summary: "create")
                return text(
                    previewReport(saved, changed: saved.artboards.map(\.id), store: s) + "\n"
                        + previewOutline(saved, store: s))
            },

            Tool(
                name: "preview_get",
                description:
                    "Read a preview page. Default: compact outline of every artboard and layer. Pass artboard to limit it, ids (with artboard) for full JSON of layers, or full:true for the whole page JSON.",
                schema: schema(
                    [
                        "preview": prop("string", "Preview id"),
                        "artboard": prop("string", "Only this artboard"),
                        "ids": prop("array", "Layer ids to return as full JSON", extra: ["items": ["type": "string"]]),
                        "full": prop("boolean", "Whole page as JSON"),
                    ], required: ["preview"]), readOnly: true
            ) { [unowned self] a in
                let s = try requireStore()
                let p = try s.preview(try a.str("preview"))
                if a["full"]?.bool == true { return text(compactJSON(p)) }
                if let ids = a["ids"]?.array?.compactMap(\.string) {
                    let ab = try p.artboards[p.index(of: a["artboard"]?.string ?? p.artboards.first?.id ?? "")]
                    let nodes = ids.compactMap { id in ab.nodes.first { $0.id == id } }
                    let missing = ids.filter { id in !ab.nodes.contains { $0.id == id } }
                    return text(
                        "rev \(p.rev) artboard \(ab.id)\n" + nodes.map(compactJSON).joined(separator: "\n")
                            + (missing.isEmpty ? "" : "\nnot found: \(missing.joined(separator: ", "))"))
                }
                if let only = a["artboard"]?.string {
                    _ = try p.index(of: only)
                    return text(previewOutline(p, store: s, only: [only]))
                }
                return text(previewOutline(p, store: s))
            },

            Tool(
                name: "preview_apply",
                description:
                    "Edit a preview page with a batch of ops, applied atomically and validated. Layer ops are the scene ops (add, set, key, remove, move, duplicate, scene) on the call's artboard (default: the first) or an op's own \"artboard\". Page ops: artboard_add {id,name,size,x,y,background,copy_from}, artboard_set {id,…}, artboard_duplicate {id,as,name} (a variant to the right), artboard_remove {id}, artboard_move {id,index}, preview {name,theme}. Returns the new rev and changed layers.",
                schema: schema(
                    [
                        "preview": prop("string", "Preview id"),
                        "artboard": prop("string", "Default artboard for layer ops"),
                        "ops": prop(
                            "array",
                            "e.g. [{\"op\":\"set\",\"id\":\"title\",\"text\":\"I QUIT\"},{\"op\":\"artboard_duplicate\",\"id\":\"a\",\"as\":\"b\"},{\"op\":\"set\",\"artboard\":\"b\",\"id\":\"title\",\"fill\":\"$accent\"}]",
                            extra: ["items": ["type": "object"]]),
                        "rev": prop("integer", "Expected current rev; the write is refused if the page changed since"),
                    ], required: ["preview", "ops"])
            ) { [unowned self] a in
                let s = try requireStore()
                let p = try s.preview(try a.str("preview"))
                guard var ops = a["ops"]?.array, !ops.isEmpty else { throw ToolError("ops must be a non-empty array") }
                // Size presets ("shorts") work in artboard ops too. Only there, and only for text: a layer's `size` is
                // its font size, and JSONValue.string also renders numbers as text.
                ops = try ops.map { op in
                    guard var o = op.object, o["op"]?.string?.hasPrefix("artboard_") == true,
                        let z = o["size"], case .string = z
                    else { return op }
                    o["size"] = .array((try MCPServer.artboardSize(z) ?? []).map { .number(Double($0)) })
                    return .object(o)
                }
                let r = try PreviewOps.apply(ops, to: p, artboard: a["artboard"]?.string)
                let saved = try saveValidated(
                    r.preview, store: s,
                    expectedRev: try a["rev"]?.double.map { try SafeNumber.int($0, "rev", in: 0...SafeNumber.maxCount) },
                    summary: r.summary)
                return text(previewReport(saved, changed: r.changed, store: s))
            },

            Tool(
                name: "preview_delete",
                description: "Delete a preview page (its history stays in .history).",
                schema: schema(["preview": prop("string", "Preview id")], required: ["preview"])
            ) { [unowned self] a in
                let s = try requireStore()
                let id = try a.str("preview")
                _ = try s.preview(id)
                try s.deletePreview(id)
                return text("deleted preview \(id)")
            },

            Tool(
                name: "preview_render",
                description:
                    "Render a preview's artboards into one labelled image to check your work. feed:true also shows each artboard at YouTube feed size (about 360x202) with a timestamp badge, which is how most viewers first see a thumbnail: check that the main words still read.",
                schema: schema(
                    [
                        "preview": prop("string", "Preview id"),
                        "artboards": prop("array", "Artboard ids; default all", extra: ["items": ["type": "string"]]),
                        "scale": prop("number", "Scale per artboard, default 0.4"),
                        "feed": prop("boolean", "Add feed-size versions with a timestamp badge"),
                        "save": prop("string", "Optional path to also save the sheet as PNG"),
                    ], required: ["preview"]), readOnly: true
            ) { [unowned self] a in
                let s = try requireStore()
                let p = try s.preview(try a.str("preview"))
                let ids = a["artboards"]?.array?.compactMap(\.string) ?? p.artboards.map(\.id)
                let boards = try ids.prefix(9).map { p.artboards[try p.index(of: $0)] }
                guard !boards.isEmpty else { throw ToolError("the preview has no artboards") }
                let scale = min(max(a["scale"]?.double ?? 0.4, 0.05), 1)
                let r = try renderer()
                let project = s.project.rendering(p)
                var imgs: [CGImage] = [], labels: [String] = []
                for b in boards {
                    let img = try r.image(
                        scene: b.asScene(preview: p.id), project: project, assets: s.assetsURL, time: 0, scale: scale)
                    imgs.append(img); labels.append("\(b.id) \(b.width)x\(b.height)")
                    if a["feed"]?.bool == true {
                        let feed = try r.image(
                            scene: b.asScene(preview: p.id), project: project, assets: s.assetsURL, time: 0,
                            scale: 360 / Double(max(b.width, 1)))
                        imgs.append(FeedMock.badge(feed)); labels.append("\(b.id) feed")
                    }
                }
                let sheet = try ContactSheet.tile(imgs, labels: labels)
                if let path = a["save"]?.string { try ImageFile.writePNG(sheet, to: URL(expandingPath: path)) }
                guard let jpg = ContactSheet.jpeg(sheet) else { throw ToolError("encode failed") }
                return [
                    ["type": "image", "data": .string(jpg.base64EncodedString()), "mimeType": "image/jpeg"],
                    ["type": "text", "text": .string("\(p.id) rev \(p.rev): \(labels.joined(separator: ", "))")],
                ]
            },
        ]
    }
}
