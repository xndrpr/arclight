import ArclightCore
import Foundation

extension MCPServer {
    func sceneTools() -> [Tool] {
        [
            Tool(
                name: "scene_create",
                description:
                    "Create (or overwrite with overwrite:true) a scene. Pass every node at once to build a whole graphic in one call. Optionally copy another scene as a starting point.",
                schema: schema(
                    [
                        "id": prop("string", "Scene id (file name), e.g. \"stat-45\""),
                        "duration": prop("number", "Seconds, default 5"),
                        "background": prop("string", "Color or token, default $bg"),
                        "camera": prop("object", "3D camera (see guide 3d); may be keyframed {\"k\":[...]}"),
                        "fog": prop("object", "{\"color\",\"near\",\"far\"} for the 3D layer"),
                        "post": prop(
                            "object", "Grade: exposure, contrast, saturation, vignette, grain, bloom (see guide post)"),
                        "nodes": prop("array", "Node objects (see guide)", extra: ["items": ["type": "object"]]),
                        "copy_from": prop("string", "Existing scene id to copy nodes/settings from"),
                        "overwrite": prop("boolean", "Replace an existing scene with this id"),
                    ],
                    required: ["id"])
            ) { [unowned self] a in
                let s = try requireStore()
                let id = try SafeName.id(try a.str("id"))
                if s.scenes[id] != nil && a["overwrite"]?.bool != true {
                    throw ToolError("scene '\(id)' exists — use scene_apply, or overwrite:true")
                }
                var scene = Scene(id: id)
                if let from = a["copy_from"]?.string {
                    scene = try s.scene(from); scene.id = id; scene.rev = s.scenes[id]?.rev ?? 0
                }
                if let d = a["duration"]?.double { scene.duration = try SceneOps.duration(d) }
                if let bg = a["background"] { scene.background = try Prop(json: bg) }
                if let c = a["camera"] { scene.camera = try Prop(json: c) }
                if let f = a["fog"] { scene.fog = try Prop(json: f) }
                if let p = a["post"] { scene.post = try Prop(json: p) }
                if let nodes = a["nodes"]?.array {
                    scene.nodes = try nodes.enumerated().map { i, n in
                        do { return try SceneOps.decodeNode(n) } catch { throw ToolError("node \(i): \(error)") }
                    }
                }
                let saved = try saveValidated(scene, store: s, expectedRev: nil, summary: "create")
                return text(applyReport(saved, changed: saved.nodes.map(\.id), store: s))
            },

            Tool(
                name: "scene_get",
                description:
                    "Read a scene. Default: compact outline (one line per node, animated props marked ~). Pass ids for full JSON of specific nodes, or full:true for the whole scene JSON.",
                schema: schema(
                    [
                        "scene": prop("string", "Scene id"),
                        "ids": prop("array", "Node ids to return as full JSON", extra: ["items": ["type": "string"]]),
                        "full": prop("boolean", "Whole scene as JSON"),
                    ], required: ["scene"]), readOnly: true
            ) { [unowned self] a in
                let s = try requireStore()
                let scene = try s.scene(try a.str("scene"))
                if a["full"]?.bool == true { return text(compactJSON(scene)) }
                if let ids = a["ids"]?.array?.compactMap(\.string) {
                    let nodes = ids.compactMap { scene.node($0) }
                    let missing = ids.filter { scene.node($0) == nil }
                    return text(
                        "rev \(scene.rev)\n" + nodes.map(compactJSON).joined(separator: "\n")
                            + (missing.isEmpty ? "" : "\nnot found: \(missing.joined(separator: ", "))"))
                }
                return text(Outline.scene(scene, project: s.project))
            },

            Tool(
                name: "scene_apply",
                description:
                    "Edit a scene with a batch of ops, applied atomically and validated (see guide topic \"ops\"). Ops: add, set, key, remove, move, duplicate, shift, scene. Returns new rev and changed node outlines.",
                schema: schema(
                    [
                        "scene": prop("string", "Scene id"),
                        "ops": prop(
                            "array", "e.g. [{\"op\":\"set\",\"id\":\"title\",\"text\":\"NEW\",\"size\":140}]",
                            extra: ["items": ["type": "object"]]),
                        "rev": prop("integer", "Expected current rev; the write is refused if the scene changed since"),
                    ],
                    required: ["scene", "ops"])
            ) { [unowned self] a in
                let s = try requireStore()
                let scene = try s.scene(try a.str("scene"))
                guard let ops = a["ops"]?.array, !ops.isEmpty else { throw ToolError("ops must be a non-empty array") }
                let r = try SceneOps.apply(ops, to: scene)
                let saved = try saveValidated(
                    r.scene, store: s,
                    expectedRev: try a["rev"]?.double.map {
                        try SafeNumber.int($0, "rev", in: 0...SafeNumber.maxCount)
                    },
                    summary: r.summary)
                return text(applyReport(saved, changed: r.changed, store: s))
            },

            Tool(
                name: "scene_delete",
                description: "Delete a scene (its history stays in .history).",
                schema: schema(["scene": prop("string", "Scene id")], required: ["scene"])
            ) { [unowned self] a in
                let s = try requireStore()
                let id = try a.str("scene")
                _ = try s.scene(id)
                try s.deleteScene(id)
                return text("deleted \(id)")
            },
        ]
    }
}
