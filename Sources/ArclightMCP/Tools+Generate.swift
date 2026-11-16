import ArclightCore
import CoreGraphics
import Foundation
import simd

/// AI pixel tools for agents: background removal (on-device, free), and with the user's fal.ai key generation,
/// generative fill, expand and upscale. Every result is a new asset plus a normal (revertible) layer edit.
extension MCPServer {
    /// Where a layer lives: a motion scene, or an artboard of a thumbnail page.
    struct LayerHost {
        let scene: Scene
        let project: Project
        let describe: String
        let save: (_ ops: [JSONValue], _ summary: String) throws -> String
    }

    func layerHost(_ a: [String: JSONValue], store s: ProjectStore) throws -> LayerHost {
        if let pid = a["thumbnail"]?.string {
            let p = try s.thumbnail(pid)
            guard let ab = p.artboard(a["artboard"]?.string) else {
                throw ToolError("no artboard '\(a["artboard"]?.string ?? "")' in thumbnail \(pid)")
            }
            return LayerHost(
                scene: ab.asScene(thumbnail: p.id, rev: p.rev), project: s.project.rendering(p),
                describe: "\(p.id)/\(ab.id)"
            ) { [unowned self] ops, summary in
                guard !ops.isEmpty else { return "" }
                let r = try ThumbnailOps.apply(ops, to: p, artboard: ab.id)
                let saved = try saveValidated(r.thumbnail, store: s, expectedRev: p.rev, summary: summary)
                return thumbnailReport(saved, changed: r.changed, store: s)
            }
        }
        let scene = try s.scene(try a.str("scene"))
        return LayerHost(scene: scene, project: s.project, describe: scene.id) { [unowned self] ops, summary in
            guard !ops.isEmpty else { return "" }
            let r = try SceneOps.apply(ops, to: scene)
            let saved = try saveValidated(r.scene, store: s, expectedRev: scene.rev, summary: summary)
            return applyReport(saved, changed: r.changed, store: s)
        }
    }

    /// fal.ai, if the user enabled it and saved a key (tests inject their own).
    func falProvider() throws -> ImageProvider {
        if let p = imageProviderOverride { return p }
        guard ImageSettings.enabled, let p = KeychainStore.falProvider() else {
            throw ToolError("\(ImageAIError.noKey)")
        }
        return p
    }

    /// The provider for one `image_generate` call: Settings' generate model, or `model` when the call names one.
    func generateProvider(model: String?) throws -> ImageProvider {
        let model = model?.trimmingCharacters(in: .whitespaces).lowercased()
        if let model, !model.isEmpty, !FalProvider.isModelID(model) {
            throw ToolError("model '\(model)' isn't a fal model id like fal-ai/flux/dev")
        }
        let p = try falProvider()
        guard let model, !model.isEmpty, let fal = p as? FalProvider else { return p }
        return fal.generating(with: model)
    }

    private static let hostProps: [String: JSONValue] = [
        "scene": prop("string", "Scene id (or use thumbnail + artboard)"),
        "thumbnail": prop("string", "Thumbnail page id"),
        "artboard": prop("string", "Artboard id (default: the page's first)"),
    ]

    private static func with(_ extra: [String: JSONValue]) -> [String: JSONValue] {
        hostProps.merging(extra) { _, b in b }
    }

    func generateTools() -> [Tool] {
        [
            Tool(
                name: "image_status",
                description:
                    "Which AI image operations are available: background removal and subject selection always (on-device); generate, fill, expand and upscale need the user's fal.ai key (Settings ▸ AI).",
                schema: schema([:]), readOnly: true
            ) { [unowned self] _ in
                let fal = imageProviderOverride != nil || (ImageSettings.enabled && KeychainStore.falKey() != nil)
                let m = ImageSettings.models
                var lines = [
                    "on-device (Apple Vision): image_remove_bg, image_select_subject — always available",
                    fal
                        ? "fal.ai: on — generate \(m.generate) (image_generate model can pick another fal text-to-image id per call), fill/expand \(m.fill), background \(m.removeBackground), upscale \(m.upscale)"
                        : "fal.ai: off — the user can add a key in Settings ▸ AI ▸ Image generation (image_generate, image_fill, image_expand, image_upscale need it)",
                ]
                if let s = store {
                    let h = ImageAI.history(s).suffix(5)
                    if !h.isEmpty {
                        lines.append("recent: " + h.map { "\($0.op) → \($0.asset)" }.joined(separator: ", "))
                    }
                }
                return text(lines.joined(separator: "\n"))
            },

            Tool(
                name: "image_remove_bg",
                description:
                    "Cut the subject out of an image layer (transparent background), then e.g. give it effects.outline for the thumbnail sticker look. engine local (default, on-device, free) or fal. Writes a new asset and points the layer at it (revertible).",
                schema: schema(
                    MCPServer.with([
                        "layer": prop("string", "Image layer id"),
                        "engine": prop("string", "local (default) or fal", extra: ["enum": ["local", "fal"]]),
                    ]), required: ["layer"])
            ) { [unowned self] a in
                let s = try requireStore()
                let h = try layerHost(a, store: s)
                let engine = ImageAI.CutoutEngine(rawValue: a["engine"]?.string ?? "local") ?? .local
                let fal = engine == .fal ? try falProvider() : nil
                let layer = try a.str("layer")
                let scene = h.scene
                let r = try blocking {
                    try await ImageAI.removeBackground(layer: layer, in: scene, store: s, engine: engine, fal: fal)
                }
                return text("asset \(r.asset)\n" + (try h.save(r.ops, r.summary)))
            },

            Tool(
                name: "image_select_subject",
                description:
                    "Find the subject (person, animal, object) in an image layer, on-device. Returns its bounding box in canvas px [x, y, w, h], e.g. for image_fill or to place text beside it.",
                schema: schema(MCPServer.with(["layer": prop("string", "Image layer id")]), required: ["layer"]),
                readOnly: true
            ) { [unowned self] a in
                let s = try requireStore()
                let h = try layerHost(a, store: s)
                let r = try renderer()
                r.evaluator.theme = h.project.theme
                let nodes = r.evaluator.evaluate(h.scene, T: 0)
                guard let rect = try ImageAI.subjectRect(layer: try a.str("layer"), in: h.scene, store: s, nodes: nodes)
                else { return text("no subject found") }
                let v = [rect.minX, rect.minY, rect.width, rect.height].map { Int($0.rounded()) }
                return text("subject [\(v.map(String.init).joined(separator: ", "))]")
            },

            Tool(
                name: "image_generate",
                description:
                    "Generate a picture from a prompt (fal.ai, needs the user's key). Saved as an asset; with scene or thumbnail it is also placed as a new image layer (centred on x,y, default the canvas centre, fit cover). Describe subject, style, lighting; no text in the picture — add words as text layers. model picks the fal text-to-image model for this call (default: the one in Settings, see image_status), e.g. fal-ai/flux/dev or a GPT Image model id from fal; use one the user asked for.",
                schema: schema(
                    MCPServer.with([
                        "prompt": prop("string", "What to make"),
                        "width": prop("integer", "Pixels, default 1280"),
                        "height": prop("integer", "Pixels, default 720"),
                        "x": prop("number", "Centre x on the canvas"), "y": prop("number", "Centre y"),
                        "seed": prop("integer", "Repeatable result (models that support it)"),
                        "model": prop("string", "fal model id for this call, e.g. fal-ai/flux/dev (default: Settings)"),
                    ]), required: ["prompt"])
            ) { [unowned self] a in
                let s = try requireStore()
                let provider = try generateProvider(model: a["model"]?.string)
                let place = a["scene"] != nil || a["thumbnail"] != nil
                let h = place ? try layerHost(a, store: s) : nil
                let w = try SafeNumber.int(a["width"]?.double ?? 1280, "width", in: 64...4096)
                let hh = try SafeNumber.int(a["height"]?.double ?? 720, "height", in: 64...4096)
                let at: CGPoint? = a["x"]?.double.flatMap { x in a["y"]?.double.map { CGPoint(x: x, y: $0) } }
                let prompt = try a.str("prompt")
                let seed = a["seed"]?.double.map { Int($0) }
                let scene = h?.scene, project = h?.project
                let r = try blocking {
                    try await ImageAI.generate(
                        prompt: prompt, width: w, height: hh, in: scene, project: project, store: s, provider: provider,
                        place: place, at: at, seed: seed)
                }
                return text("asset \(r.asset)" + (h.map { "\n" + ((try? $0.save(r.ops, r.summary)) ?? "") } ?? ""))
            },

            Tool(
                name: "image_fill",
                description:
                    "Generative fill (fal.ai, needs the user's key): repaint an area of the rendered scene/artboard from a prompt — remove an object, add one, extend a background. The result is a new image layer covering the area, on top (or above `above`). Area: rect [x,y,w,h] in canvas px, or a layer id (its bounds).",
                schema: schema(
                    MCPServer.with([
                        "prompt": prop("string", "What should be there"),
                        "rect": prop("array", "[x, y, w, h] canvas px", extra: ["items": ["type": "number"]]),
                        "area_layer": prop("string", "Use this layer's bounds as the area"),
                        "above": prop("string", "Insert the result above this layer (default: on top)"),
                    ]), required: ["prompt"])
            ) { [unowned self] a in
                let s = try requireStore()
                let h = try layerHost(a, store: s)
                let provider = try falProvider()
                let r = try renderer()
                var rect: CGRect
                if let v = a["rect"]?.doubles, v.count == 4 {
                    rect = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
                } else if let lid = a["area_layer"]?.string {
                    r.evaluator.theme = h.project.theme
                    guard let n = r.evaluator.evaluate(h.scene, T: 0).first(where: { $0.node.id == lid }),
                        let b = r.localBounds(n)
                    else { throw ToolError("no bounds for layer '\(lid)'") }
                    let pts = [(b.minX, b.minY), (b.maxX, b.minY), (b.minX, b.maxY), (b.maxX, b.maxY)].map {
                        n.world * SIMD4<Float>(Float($0.0), Float($0.1), 0, 1)
                    }
                    let xs = pts.map { CGFloat($0.x) }, ys = pts.map { CGFloat($0.y) }
                    rect = CGRect(
                        x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                } else {
                    throw ToolError("give rect [x,y,w,h] or area_layer")
                }
                let prompt = try a.str("prompt")
                let scene = h.scene, project = h.project, above = a["above"]?.string, area = rect
                let res = try blocking {
                    try await ImageAI.fill(
                        rect: area, prompt: prompt, in: scene, project: project, store: s, renderer: r,
                        provider: provider, above: above)
                }
                return text("asset \(res.asset)\n" + (try h.save(res.ops, res.summary)))
            },

            Tool(
                name: "image_expand",
                description:
                    "Outpaint an image layer (fal.ai, needs the user's key): add left/top/right/bottom picture pixels of generated content, e.g. to turn a tight photo into a 16:9 background. The layer grows so the original stays in place.",
                schema: schema(
                    MCPServer.with([
                        "layer": prop("string", "Image layer id"),
                        "left": prop("integer", "Pixels"), "top": prop("integer", "Pixels"),
                        "right": prop("integer", "Pixels"), "bottom": prop("integer", "Pixels"),
                        "prompt": prop("string", "Optional guidance for the new area"),
                    ]), required: ["layer"])
            ) { [unowned self] a in
                let s = try requireStore()
                let h = try layerHost(a, store: s)
                let provider = try falProvider()
                func side(_ k: String) throws -> Int { try SafeNumber.int(a[k]?.double ?? 0, k, in: 0...4096) }
                let (l, t, rr, b) = (try side("left"), try side("top"), try side("right"), try side("bottom"))
                let layer = try a.str("layer"), prompt = a["prompt"]?.string ?? "", scene = h.scene
                let r = try blocking {
                    try await ImageAI.expand(
                        layer: layer, in: scene, store: s, left: l, top: t, right: rr, bottom: b, prompt: prompt,
                        provider: provider)
                }
                return text("asset \(r.asset)\n" + (try h.save(r.ops, r.summary)))
            },

            Tool(
                name: "image_upscale",
                description:
                    "Upscale an image layer's picture ×2–×4 (fal.ai, needs the user's key) so a small photo stays sharp on a 1280×720 thumbnail. Same size on the canvas, more pixels.",
                schema: schema(
                    MCPServer.with([
                        "layer": prop("string", "Image layer id"), "factor": prop("integer", "2 (default) to 4"),
                    ]), required: ["layer"])
            ) { [unowned self] a in
                let s = try requireStore()
                let h = try layerHost(a, store: s)
                let provider = try falProvider()
                let f = try SafeNumber.int(a["factor"]?.double ?? 2, "factor", in: 2...4)
                let layer = try a.str("layer"), scene = h.scene
                let r = try blocking {
                    try await ImageAI.upscale(layer: layer, in: scene, store: s, factor: f, provider: provider)
                }
                return text("asset \(r.asset)\n" + (try h.save(r.ops, r.summary)))
            },
        ]
    }
}
