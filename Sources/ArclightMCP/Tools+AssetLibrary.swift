import ArclightCore
import Foundation

/// Free ready-made 3D models and textures (Poly Haven, CC0): search, then import into assets/ and optionally place
/// a model in a scene. No key, no cost — the first place to look before model_generate or a generated texture.
extension MCPServer {
    var assetLibrary: AssetLibrary { assetLibraryOverride ?? AssetLibrary() }

    func assetLibraryTools() -> [Tool] {
        [
            Tool(
                name: "library_search",
                description:
                    "Search the free asset library (Poly Haven: ~500 realistic 3D models — furniture, props, plants, food, tools, decor, lights — and ~900 tiling PBR textures — wood, stone, fabric, metal, ground; all CC0, free). Free and instant: look here first before model_generate ($0.02–0.40 a model) or generating a texture. Returns ids with name, polycount, real size and tags. Search in English with one or two plain nouns (\"plant pot\", \"oak floor\"). Nothing for characters, animals or stylised things: generate those.",
                schema: schema(
                    [
                        "query": prop(
                            "string", "What to find, in English, e.g. \"wooden table\" or \"terracotta pot\""),
                        "kind": prop("string", "model (default) or texture", extra: ["enum": ["model", "texture"]]),
                        "limit": prop("integer", "Results, default 8 (max 20)"),
                    ], required: ["query"]),
                readOnly: true
            ) { [unowned self] a in
                let kind = AssetLibrary.Kind(rawValue: a["kind"]?.string ?? "model") ?? .model
                let q = try a.str("query")
                let limit = try SafeNumber.int(a["limit"]?.double ?? 8, "limit", in: 1...20)
                let lib = assetLibrary
                let items = try blocking { try await lib.search(q, kind: kind, limit: limit) }
                guard !items.isEmpty else {
                    return text(
                        "nothing in the library for “\(q)” (\(kind.rawValue)s). Try another plain noun, or generate it (\(kind == .model ? "model_generate" : "image_generate with a seamless texture prompt"))."
                    )
                }
                return text(
                    items.map(\.line).joined(separator: "\n")
                        + "\nlibrary_import {id\(kind == .model ? ", scene to place it" : "")} to use one (free).")
            },

            Tool(
                name: "library_import",
                description:
                    "Import a free library asset (from library_search) into assets/. A model becomes one .glb; with scene it is also placed as a model layer at x,y,z (size px, default from its real size relative to 400 px per metre… pass size to choose). A texture becomes a .jpg colour map for a box face or image ({\"src\": file, \"tile\": [u, v]}). Returns the asset, and for models a turntable sheet to check it.",
                schema: schema(
                    [
                        "id": prop("string", "Library id from library_search"),
                        "kind": prop("string", "model (default) or texture", extra: ["enum": ["model", "texture"]]),
                        "resolution": prop(
                            "string", "Texture resolution: 1k (default) or 2k", extra: ["enum": ["1k", "2k"]]),
                        "scene": prop("string", "Scene to place a model in (optional)"),
                        "x": prop("number", "Layer x (default canvas centre)"),
                        "y": prop("number", "Layer y (default canvas centre)"),
                        "z": prop("number", "Layer z (default 0)"),
                        "size": prop("number", "Largest side in px (default 400)"),
                        "layer": prop("string", "Layer id (default from the asset)"),
                    ], required: ["id"])
            ) { [unowned self] a in
                let s = try requireStore()
                let id = try a.str("id")
                guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
                    throw ToolError("id '\(id)' isn't a library id")
                }
                let kind = AssetLibrary.Kind(rawValue: a["kind"]?.string ?? "model") ?? .model
                let res = a["resolution"]?.string == "2k" ? "2k" : "1k"
                if let sid = a["scene"]?.string { _ = try s.scene(sid) }
                let lib = assetLibrary
                if kind == .texture {
                    let name = try blocking { try await lib.importTexture(id, resolution: res, store: s) }
                    return text(
                        "asset \(name) (free, CC0) — use as {\"src\": \"\(name)\", \"tile\": [2, 2]} on a box face or as an image"
                    )
                }
                let name = try blocking { try await lib.importModel(id, resolution: res, store: s) }
                var lines = ["asset \(name) (free, CC0 from Poly Haven)"]
                if let sid = a["scene"]?.string {
                    let scene = try s.scene(sid)
                    let (w, h) = s.project.size(for: scene)
                    let base = a["layer"]?.string ?? ((name as NSString).deletingPathExtension)
                    let node: [String: JSONValue] = [
                        "id": .string(SceneOps.uniqueId(base, in: scene)), "type": "model", "src": .string(name),
                        "x": .number(a["x"]?.double ?? Double(w) / 2), "y": .number(a["y"]?.double ?? Double(h) / 2),
                        "z": .number(a["z"]?.double ?? 0), "size": .number(a["size"]?.double ?? 400),
                    ]
                    let applied = try SceneOps.apply([["op": "add", "node": .object(node)]], to: scene)
                    let saved = try saveValidated(applied.scene, store: s, expectedRev: scene.rev, summary: "add \(id)")
                    lines.append(applyReport(saved, changed: applied.changed, store: s))
                }
                var out: [JSONValue] = []
                if let r3 = try? renderer(),
                    let img = try? ContactSheet.render(
                        renderer: r3, scene: ModelAI.turntable(name, project: s.project), project: s.project,
                        assets: s.assetsURL, times: [0, 1, 2, 3], scale: 0.2),
                    let jpg = ContactSheet.jpeg(img)
                {
                    out.append(["type": "image", "data": .string(jpg.base64EncodedString()), "mimeType": "image/jpeg"])
                }
                return out + text(lines.joined(separator: "\n"))
            },
        ]
    }
}
