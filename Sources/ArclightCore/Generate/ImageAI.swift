import CoreGraphics
import Foundation
import simd

/// AI image operations on layers. Each one writes its result into the project's assets/ (via `AssetWriter`), logs
/// what made it in `.arclight/generations.jsonl`, and returns layer ops for the caller to apply — the editor through
/// its undoable working copy, MCP through a validated save — so every result is a normal, revertible edit. The
/// original picture is never overwritten.
public enum ImageAI {
    public struct Result: Sendable {
        public var asset: String
        public var ops: [JSONValue]
        public var summary: String
        /// The layer the result is on (new or existing).
        public var layer: String
    }

    /// Which provider removes backgrounds: on-device Vision (default, free) or fal.ai.
    public enum CutoutEngine: String, Sendable { case local, fal }

    // MARK: Background removal

    public static func removeBackground(
        layer id: String, in scene: Scene, store: ProjectStore, engine: CutoutEngine = .local, fal: ImageProvider? = nil
    ) async throws -> Result {
        let (n, src, img) = try imageLayer(id, scene, store)
        let out: CGImage
        switch engine {
        case .local: out = try LocalVisionProvider().removeBackground(image: img)
        case .fal:
            guard let fal else { throw ImageAIError.noKey }
            out = try await fal.removeBackground(image: img)
        }
        let name = try write(out, base: stem(src) + "-cutout", store: store)
        log(
            store, op: "remove_bg", model: engine == .local ? "apple-vision" : "fal", prompt: nil, source: src,
            asset: name)
        var ops: [JSONValue] = [["op": "set", "id": .string(n.id), "src": .string(name)]]
        // Keep the drawn size when the layer took it from the picture.
        if n.props["width"] == nil && n.props["height"] == nil {
            ops[0] = ["op": "set", "id": .string(n.id), "src": .string(name), "width": .number(Double(img.width))]
        }
        return Result(asset: name, ops: ops, summary: "removed background of \(n.id)", layer: n.id)
    }

    // MARK: Upscale

    public static func upscale(
        layer id: String, in scene: Scene, store: ProjectStore, factor: Int, provider: ImageProvider
    ) async throws -> Result {
        let (n, src, img) = try imageLayer(id, scene, store)
        let out = try await provider.upscale(image: img, factor: max(2, min(4, factor)))
        let name = try write(out, base: stem(src) + "-x\(factor)", store: store)
        log(store, op: "upscale", model: provider.name, prompt: nil, source: src, asset: name)
        var o: [String: JSONValue] = ["op": "set", "id": .string(n.id), "src": .string(name)]
        // Same size on the canvas, more pixels.
        if n.props["width"] == nil && n.props["height"] == nil { o["width"] = .number(Double(img.width)) }
        return Result(asset: name, ops: [.object(o)], summary: "upscaled \(n.id) ×\(factor)", layer: n.id)
    }

    // MARK: Depth (relief)

    /// Makes a depth map of an image layer's picture and turns the layer into a relief: a 3D surface pushed towards
    /// the camera where the picture is near, so a camera move through it has real parallax.
    public static func depth(
        layer id: String, in scene: Scene, store: ProjectStore, provider: ImageProvider, amount: Double? = nil
    ) async throws -> Result {
        let (n, src, img) = try imageLayer(id, scene, store)
        let out = try await provider.depth(image: img)
        let name = try write(out, base: stem(src) + "-depth", store: store)
        log(store, op: "depth", model: provider.name, prompt: nil, source: src, asset: name)
        var o: [String: JSONValue] = ["op": "set", "id": .string(n.id), "depth": .string(name)]
        if n.props["3d"] == nil { o["3d"] = true }
        if let amount {
            o["depthAmount"] = .number(amount)
        } else if n.props["depthAmount"] == nil {
            // A fifth of the picture's drawn width reads as depth without tearing at the edges.
            let w = n.props["width"].flatMap { if case .value(let v) = $0 { return v.double } else { return nil } }
            o["depthAmount"] = .number(((w ?? Double(img.width)) * 0.2).rounded())
        }
        return Result(asset: name, ops: [.object(o)], summary: "depth for \(n.id)", layer: n.id)
    }

    // MARK: Expand (outpaint)

    /// Extends an image layer's picture by `left`/`top`/`right`/`bottom` picture pixels with generated content; the
    /// layer grows so the original part stays exactly where it was.
    public static func expand(
        layer id: String, in scene: Scene, store: ProjectStore, left: Int, top: Int, right: Int, bottom: Int,
        prompt: String, provider: ImageProvider
    ) async throws -> Result {
        let (n, src, img) = try imageLayer(id, scene, store)
        guard left + top + right + bottom > 0 else { throw ImageAIError.failed("expand by at least one side") }
        guard let (canvas, mask) = ImageData.padded(img, left: left, top: top, right: right, bottom: bottom) else {
            throw ImageAIError.badImage
        }
        var out = try await provider.fill(
            image: canvas, mask: mask, prompt: prompt.isEmpty ? "continue the picture naturally" : prompt, seed: nil)
        if out.width != canvas.width || out.height != canvas.height {
            out = ImageData.resize(out, canvas.width, canvas.height) ?? out
        }
        let name = try write(out, base: stem(src) + "-expanded", store: store)
        log(store, op: "expand", model: provider.name, prompt: prompt, source: src, asset: name)
        // Drawn size per picture pixel, and the shift that keeps the old picture in place (layers are centred).
        let shownW =
            n.props["width"].flatMap { if case .value(let v) = $0 { return v.double } else { return nil } }
            ?? n.props["height"].flatMap { if case .value(let v) = $0 { return v.double } else { return nil } }.map {
                $0 * Double(img.width) / Double(img.height)
            } ?? Double(img.width)
        let k = shownW / Double(img.width)
        let dx = Double(right - left) / 2 * k, dy = Double(bottom - top) / 2 * k
        var o: [String: JSONValue] = [
            "op": "set", "id": .string(n.id), "src": .string(name),
            "width": .number((Double(out.width) * k).rounded()), "height": .number((Double(out.height) * k).rounded()),
        ]
        if case .value(let x)? = n.props["x"], let xv = x.double { o["x"] = .number((xv + dx).rounded()) }
        if case .value(let y)? = n.props["y"], let yv = y.double { o["y"] = .number((yv + dy).rounded()) }
        if n.props["fit"] != nil { o["fit"] = .null }
        if n.props["crop"] != nil { o["crop"] = .null }
        return Result(asset: name, ops: [.object(o)], summary: "expanded \(n.id)", layer: n.id)
    }

    // MARK: Generative fill

    /// Paints `rect` (canvas pixels) of the rendered scene / artboard following `prompt`; the result is a new image
    /// layer covering exactly that rectangle, on top (or above `above`), so the original layers stay editable.
    public static func fill(
        rect: CGRect, prompt: String, in scene: Scene, project: Project, store: ProjectStore, renderer: Renderer,
        provider: ImageProvider, above: String? = nil, time: Double = 0
    ) async throws -> Result {
        let (cw, ch) = project.size(for: scene)
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: cw, height: ch))
        guard r.width >= 8, r.height >= 8 else { throw ImageAIError.failed("select an area of at least 8×8 px") }
        let frame = try renderer.image(scene: scene, project: project, assets: store.assetsURL, time: time)
        // Context around the selection helps the model; send a window of up to twice its size.
        let pad = max(r.width, r.height) / 2
        let window = r.insetBy(dx: -pad, dy: -pad).intersection(CGRect(x: 0, y: 0, width: cw, height: ch)).integral
        guard let crop = ImageData.crop(frame, window),
            let mask = ImageData.mask(
                width: crop.width, height: crop.height, white: r.offsetBy(dx: -window.minX, dy: -window.minY))
        else { throw ImageAIError.badImage }
        var out = try await provider.fill(image: crop, mask: mask, prompt: prompt, seed: nil)
        if out.width != crop.width || out.height != crop.height {
            out = ImageData.resize(out, crop.width, crop.height) ?? out
        }
        guard let piece = ImageData.crop(out, r.offsetBy(dx: -window.minX, dy: -window.minY)) else {
            throw ImageAIError.badImage
        }
        let name = try write(piece, base: "fill-" + slug(prompt), store: store)
        log(store, op: "fill", model: provider.name, prompt: prompt, source: nil, asset: name)
        let id = SceneOps.uniqueId("fill", in: scene)
        var add: [String: JSONValue] = [
            "op": "add",
            "node": [
                "id": .string(id), "type": "image", "name": .string("Fill: \(prompt.prefix(40))"), "src": .string(name),
                "x": .number(r.midX), "y": .number(r.midY), "width": .number(r.width), "height": .number(r.height),
            ],
        ]
        if let above, scene.node(above) != nil { add["after"] = .string(above) }
        return Result(asset: name, ops: [.object(add)], summary: "generative fill “\(prompt.prefix(40))”", layer: id)
    }

    // MARK: Generate

    /// A new picture from a prompt, saved as an asset; with `place`, also a new image layer centred on `at`
    /// (default: the canvas centre) at `width`×`height` canvas px.
    public static func generate(
        prompt: String, width: Int, height: Int, in scene: Scene?, project: Project?, store: ProjectStore,
        provider: ImageProvider, place: Bool, at: CGPoint? = nil, seed: Int? = nil
    ) async throws -> Result {
        // Generators work in multiples of 16 (and want at least 256 px a side).
        func snap(_ v: Int) -> Int { max(256, min(2048, (v + 8) / 16 * 16)) }
        let img = try await provider.generate(prompt: prompt, width: snap(width), height: snap(height), seed: seed)
        let name = try write(img, base: "gen-" + slug(prompt), store: store)
        log(
            store, op: "generate", model: (provider as? FalProvider)?.models.generate ?? provider.name, prompt: prompt,
            source: nil, asset: name)
        guard place, let scene, let project else {
            return Result(asset: name, ops: [], summary: "generated \(name)", layer: "")
        }
        let (cw, ch) = project.size(for: scene)
        let c = at ?? CGPoint(x: cw / 2, y: ch / 2)
        let id = SceneOps.uniqueId("image", in: scene)
        let add: JSONValue = [
            "op": "add",
            "node": [
                "id": .string(id), "type": "image", "name": .string(String(prompt.prefix(40))), "src": .string(name),
                "x": .number(c.x.rounded()), "y": .number(c.y.rounded()), "width": .number(Double(width)),
                "height": .number(Double(height)), "fit": "cover",
            ],
        ]
        return Result(asset: name, ops: [add], summary: "generated “\(prompt.prefix(40))”", layer: id)
    }

    /// Bounding box (canvas pixels) of the subject in an image layer, for "select subject".
    public static func subjectRect(
        layer id: String, in scene: Scene, store: ProjectStore, nodes: [EvalNode]
    ) throws
        -> CGRect?
    {
        let (n, _, img) = try imageLayer(id, scene, store)
        guard let b = try LocalVisionProvider().subjectBounds(image: img),
            let ev = nodes.first(where: { $0.node.id == n.id })
        else { return nil }
        // Picture pixels → layer space (centred box) → canvas via the layer's world transform.
        let w = ev.props["width"]?.double, h = ev.props["height"]?.double
        let sw = w ?? h.map { $0 * Double(img.width) / Double(img.height) } ?? Double(img.width)
        let sh = h ?? w.map { $0 * Double(img.height) / Double(img.width) } ?? Double(img.height)
        let kx = sw / Double(img.width), ky = sh / Double(img.height)
        var corners: [SIMD4<Float>] = []
        for (x, y) in [(b.minX, b.minY), (b.maxX, b.minY), (b.minX, b.maxY), (b.maxX, b.maxY)] {
            let lx = Float(Double(x) * kx - sw / 2), ly = Float(Double(y) * ky - sh / 2)
            corners.append(ev.world * SIMD4<Float>(lx, ly, 0, 1))
        }
        let xs = corners.map { CGFloat($0.x) }, ys = corners.map { CGFloat($0.y) }
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    // MARK: Helpers

    static func imageLayer(_ id: String, _ scene: Scene, _ store: ProjectStore) throws -> (Node, String, CGImage) {
        guard let n = scene.node(id) else { throw ModelError.notFound("layer '\(id)'") }
        guard n.type == "image", case .value(let v)? = n.props["src"], let src = v.string else {
            throw ImageAIError.unsupported("'\(id)' is not an image layer")
        }
        return (n, src, try ImageData.load(AssetPath.url(src, assets: store.assetsURL)))
    }

    static func stem(_ src: String) -> String {
        let base = ((src as NSString).lastPathComponent as NSString).deletingPathExtension
        return base.isEmpty ? "image" : base
    }

    static func slug(_ s: String) -> String {
        let words = s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let j = words.prefix(4).joined(separator: "-")
        return j.isEmpty ? "image" : j
    }

    /// Writes a PNG into assets/ under a name not already taken (`base.png`, `base-2.png`, …).
    static func write(_ img: CGImage, base: String, store: ProjectStore) throws -> String {
        guard let data = ImageData.png(img) else { throw ImageAIError.badImage }
        var name = "\(base).png", k = 2
        while FileManager.default.fileExists(atPath: store.assetsURL.appendingPathComponent(name).path) {
            name = "\(base)-\(k).png"; k += 1
        }
        return try AssetWriter.writeImage(data, name: name, to: store).src
    }

    struct LogEntry: Codable {
        var time: String, op: String, model: String, prompt: String?, source: String?, asset: String
    }

    static func log(_ store: ProjectStore, op: String, model: String, prompt: String?, source: String?, asset: String) {
        let e = LogEntry(time: Timestamp.string(), op: op, model: model, prompt: prompt, source: source, asset: asset)
        let dir = store.url.appendingPathComponent(".arclight")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        JSONL.append(e, to: dir.appendingPathComponent("generations.jsonl"), encoder: JSONEncoder())
    }

    /// What made each generated asset (newest last).
    public static func history(_ store: ProjectStore) -> [(op: String, prompt: String?, asset: String)] {
        let u = store.url.appendingPathComponent(".arclight/generations.jsonl")
        guard let s = try? String(contentsOf: u, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { try? JSONDecoder().decode(LogEntry.self, from: Data($0.utf8)) }
            .map { ($0.op, $0.prompt, $0.asset) }
    }
}
