import ArclightCore
import Foundation

/// Library tools: templates (reusable scenes with parameters) and symbols. This is the "design system":
/// a recurring graphic becomes one short template_instantiate call.
extension MCPServer {
    func libraryTools() -> [Tool] {
        [
            Tool(
                name: "template_list",
                description:
                    "List scene templates (built-in, user library, project) with their parameters and defaults. Prefer a template over building a common graphic from scratch.",
                schema: schema(["category": prop("string", "Optional filter, e.g. Text or Numbers")]), readOnly: true
            ) { [unowned self] a in
                let all = Templates.all(project: store?.url).filter { t in
                    a["category"]?.string.map { t.category == $0 } ?? true
                }
                let lines = all.map { t -> String in
                    let ps = t.params.map { "\($0.name)=\($0.default.map { compactJSON($0) } ?? "?")" }.joined(
                        separator: ", ")
                    return
                        "\(t.id) — \(t.name)\(t.category.map { " [\($0)]" } ?? ""): \(t.description ?? "")\n  params: \(ps)"
                }
                return text(lines.isEmpty ? "no templates" : lines.joined(separator: "\n"))
            },

            Tool(
                name: "template_instantiate",
                description:
                    "Create a scene from a template with parameter values. Missing parameters use defaults; layout adapts to the canvas size. Then refine with scene_apply.",
                schema: schema(
                    [
                        "template": prop("string", "Template id from template_list"),
                        "scene": prop("string", "New scene id"),
                        "params": prop("object", "Parameter values, e.g. {\"value\":72,\"caption\":\"…\"}"),
                        "overwrite": prop("boolean", "Replace an existing scene with this id"),
                    ],
                    required: ["template", "scene"])
            ) { [unowned self] a in
                let s = try requireStore()
                let id = try SafeName.id(try a.str("scene"), what: "scene")
                guard let t = Templates.get(try a.str("template"), project: s.url) else {
                    throw ToolError(
                        "unknown template — available: \(Templates.all(project: s.url).map(\.id).joined(separator: ", "))"
                    )
                }
                if s.scenes[id] != nil && a["overwrite"]?.bool != true {
                    throw ToolError("scene '\(id)' exists — pick another id or overwrite:true")
                }
                // Build and validate first, so a failing call leaves the project untouched.
                var scene = try Templates.instantiate(
                    t, params: a["params"]?.object ?? [:], sceneId: id, canvas: s.project.size(for: Scene(id: id)))
                scene.rev = s.scenes[id]?.rev ?? 0
                try validate(scene)
                // Add tokens the template expects (never overwrite the user's).
                if let tokens = t.theme {
                    var p = s.project
                    var changed = false
                    for (k, v) in tokens where p.theme[k] == nil { p.theme[k] = v; changed = true }
                    if changed { try s.update(project: p) }
                }
                let saved = try s.save(scene: scene, summary: "template \(t.id)", source: .ai)
                return text(applyReport(saved, changed: saved.nodes.map(\.id), store: s))
            },

            Tool(
                name: "template_save",
                description:
                    "Save a scene as a reusable template. Each param points at a value in the scene (\"<layer>.<property>\" or \"scene.<field>\") that becomes a {{placeholder}} with the current value as default.",
                schema: schema(
                    [
                        "scene": prop("string", "Source scene id"),
                        "id": prop("string", "Template id, e.g. \"brand-stat\""),
                        "name": prop("string", "Display name"),
                        "description": prop("string", "What it is for"),
                        "category": prop("string", "Optional group shown by template_list, e.g. Text or Numbers"),
                        "params": prop(
                            "array",
                            "[{\"name\":\"value\",\"target\":\"counter.value\",\"label\":\"Value\",\"kind\":\"number\"}]",
                            extra: ["items": ["type": "object"]]),
                        "scope": prop(
                            "string", "project (default) or user (all projects)", extra: ["enum": ["project", "user"]]),
                    ],
                    required: ["scene", "id", "name"])
            ) { [unowned self] a in
                let s = try requireStore()
                let scene = try s.scene(try a.str("scene"))
                var params: [(Template.Param, String)] = []
                for p in a["params"]?.array?.compactMap(\.object) ?? [] {
                    guard let n = p["name"]?.string, let target = p["target"]?.string else {
                        throw ToolError("each param needs name and target")
                    }
                    params.append(
                        (
                            Template.Param(
                                name: n, label: p["label"]?.string, kind: p["kind"]?.string, doc: p["doc"]?.string),
                            target
                        ))
                }
                var t = try Templates.make(
                    from: scene, id: try SafeName.id(try a.str("id")), name: try a.str("name"),
                    description: a["description"]?.string,
                    params: params)
                t.category = a["category"]?.string
                let url = try Templates.save(
                    t, scope: Templates.Scope(rawValue: a["scope"]?.string ?? "project") ?? .project, project: s.url)
                return text("saved template \(t.id) (\(t.params.count) params) → \(url.path)")
            },

            Tool(
                name: "project_check",
                description:
                    "Check the whole project for problems: invalid properties, broken expressions, missing fonts/images/audio/symbols, undefined theme tokens. Run before exporting.",
                schema: schema([:]), readOnly: true
            ) { [unowned self] _ in
                let s = try requireStore()
                let probs = Doctor.check(s, expr: try renderer().evaluator.expr)
                return text(Doctor.report(probs))
            },

            Tool(
                name: "asset_write",
                description:
                    "Create an image asset from data (no file needed): either `svg` (SVG markup, rendered to a PNG at `width` px) or `base64` (PNG/JPEG/HEIC/TIFF bytes). Saved in the project's assets/; returns the name to use as an image layer's src. Same name overwrites (the editor updates). SVG is rendered by macOS (basic SVG: shapes, gradients, text; font weights may be ignored — draw text as text layers instead). For icons/shapes that should stay sharp and follow theme colours, prefer symbol_save.",
                schema: schema(
                    [
                        "name": prop("string", "File name, e.g. badge.png"),
                        "svg": prop("string", "SVG document (<svg …>…</svg>)"),
                        "base64": prop("string", "Base64-encoded PNG/JPEG/HEIC/TIFF"),
                        "width": prop("number", "Output width in px for svg (default 1024)"),
                    ],
                    required: ["name"])
            ) { [unowned self] a in
                let s = try requireStore()
                let name = try SafeName.fileName(try a.str("name"))
                let w: AssetWriter.Written
                if let svg = a["svg"]?.string {
                    w = try AssetWriter.writeSVG(
                        svg, name: name, width: try SafeNumber.int(a["width"]?.double ?? 1024, "width", in: 1...8192),
                        to: s)
                } else if let b64 = a["base64"]?.string {
                    let clean = b64.replacingOccurrences(of: "^data:[^,]*,", with: "", options: .regularExpression)
                    guard let data = Data(base64Encoded: clean, options: .ignoreUnknownCharacters) else {
                        throw ToolError("base64 is not valid")
                    }
                    w = try AssetWriter.writeImage(data, name: name, to: s)
                } else {
                    throw ToolError("send either svg or base64")
                }
                return text(
                    "src: \(w.src)  (\(w.width)×\(w.height) px) — use {\"type\":\"image\",\"src\":\"\(w.src)\"}")
            },

            Tool(
                name: "symbol_save",
                description:
                    "Save a vector symbol (SVG path data, y down; the bottom of its bounds stands on the floor) so it can be used as a symbol layer ({\"type\":\"symbol\",\"symbol\":\"pack/id\"}) or in repeater items. Symbols stay crisp at any size and are filled with theme colours. Same pack/id replaces it. scope: project (default, travels with the project) or library (all projects on this Mac).",
                schema: schema(
                    [
                        "pack": prop("string", "Pack name, e.g. brand"), "id": prop("string", "Symbol id, e.g. logo"),
                        "path": prop("string", "SVG path data (the d attribute)"),
                        "name": prop("string", "Display name"),
                        "rim": prop("string", "Optional highlight path, stroked along top edges"),
                        "evenodd": prop("boolean", "Even-odd fill (holes)"),
                        "scope": prop("string", "project | library"),
                    ],
                    required: ["pack", "id", "path"])
            ) { [unowned self] a in
                let scope = AssetWriter.SymbolScope(rawValue: a["scope"]?.string ?? "project") ?? .project
                if scope == .project { _ = try requireStore() }
                let id = try AssetWriter.saveSymbol(
                    pack: try SafeName.id(try a.str("pack"), what: "pack"), id: try SafeName.id(try a.str("id")),
                    name: a["name"]?.string, path: try a.str("path"),
                    rim: a["rim"]?.string, evenOdd: a["evenodd"]?.bool ?? false, scope: scope, project: store?.url)
                return text("symbol: \(id) (\(scope.rawValue)) — use {\"type\":\"symbol\",\"symbol\":\"\(id)\"}")
            },

            Tool(
                name: "symbol_list",
                description:
                    "List symbols for repeater items ({\"symbol\":\"pack/name\"}): built-in packs, user library and the project's symbols/*.json.",
                schema: schema(["pack": prop("string", "Optional pack filter, e.g. basic or chess")]), readOnly: true
            ) { [unowned self] a in
                let all = Symbols.all(project: store?.url).filter { s in a["pack"]?.string.map { s.pack == $0 } ?? true
                }
                let packs = Dictionary(grouping: all, by: \.pack).sorted { $0.key < $1.key }
                return text(
                    packs.map { "\($0.key): " + $0.value.map { $0.id }.joined(separator: ", ") }.joined(separator: "\n")
                )
            },
        ]
    }
}
