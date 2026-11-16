import ArclightCore
import CoreGraphics
import Foundation

/// 3D models for agents: `model_generate` makes a .glb from a prompt or a picture (fal.ai image-to-3D) and can
/// place it as a model layer.
extension MCPServer {
    func modelTools() -> [Tool] {
        [
            Tool(
                name: "model_generate",
                description:
                    "Make a 3D model (.glb) of one object for a model layer (fal.ai, needs the user's key; takes a minute or two). From a prompt: a picture of the object is generated first (kept as <name>-ref.png); or from source, a picture already in assets/. Describe just the object and its material, e.g. \"faceless matte white mannequin hand, fingers relaxed\" or \"worn leather armchair\"; one object per model, no scene around it. With scene it is also placed as a model layer at x,y,z (size px, material). Returns the asset and a turntable sheet (front, right, back, left) to check it.",
                schema: schema(
                    [
                        "prompt": prop("string", "What the object is and what it's made of"),
                        "source": prop("string", "Or: a picture in assets/ to make the model from"),
                        "name": prop("string", "File name base (default from the prompt)"),
                        "scene": prop("string", "Scene to place it in as a model layer (optional)"),
                        "id": prop("string", "Layer id (default from the name)"),
                        "x": prop("number", "Layer x (default canvas centre)"),
                        "y": prop("number", "Layer y (default canvas centre)"),
                        "z": prop("number", "Layer z (default 0)"),
                        "size": prop("number", "Largest side in px (default 400)"),
                        "material": prop(
                            "string", "matte (default), glossy or clay", extra: ["enum": ["matte", "glossy", "clay"]]),
                    ])
            ) { [unowned self] a in
                let s = try requireStore()
                let provider = try falProvider()
                let prompt = a["prompt"]?.string, source = a["source"]?.string, name = a["name"]?.string
                guard prompt?.isEmpty == false || source?.isEmpty == false else {
                    throw ToolError("give a prompt or a source picture")
                }
                let r = try blocking {
                    try await ModelAI.generate(
                        prompt: prompt, source: source, name: name, store: s, provider: provider)
                }
                var lines = ["asset \(r.asset) (\(r.triangles) triangles), made from \(r.reference)"]
                if let sid = a["scene"]?.string {
                    let scene = try s.scene(sid)
                    let (w, h) = s.project.size(for: scene)
                    let base = a["id"]?.string ?? ((r.asset as NSString).deletingPathExtension)
                    var node: [String: JSONValue] = [
                        "id": .string(SceneOps.uniqueId(base, in: scene)), "type": "model", "src": .string(r.asset),
                        "x": .number(a["x"]?.double ?? Double(w) / 2), "y": .number(a["y"]?.double ?? Double(h) / 2),
                        "z": .number(a["z"]?.double ?? 0), "size": .number(a["size"]?.double ?? 400),
                    ]
                    if let m = a["material"]?.string { node["material"] = .string(m) }
                    let applied = try SceneOps.apply([["op": "add", "node": .object(node)]], to: scene)
                    let saved = try saveValidated(applied.scene, store: s, expectedRev: scene.rev, summary: "add model")
                    lines.append(applyReport(saved, changed: applied.changed, store: s))
                }
                var out: [JSONValue] = []
                let r3 = try renderer()
                let table = ModelAI.turntable(r.asset, project: s.project)
                if let img = try? ContactSheet.render(
                    renderer: r3, scene: table, project: s.project, assets: s.assetsURL, times: [0, 1, 2, 3],
                    scale: 0.2),
                    let jpg = ContactSheet.jpeg(img)
                {
                    out.append(["type": "image", "data": .string(jpg.base64EncodedString()), "mimeType": "image/jpeg"])
                }
                return out + text(lines.joined(separator: "\n"))
            }
        ]
    }
}
