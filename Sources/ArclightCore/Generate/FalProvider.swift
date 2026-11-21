import CoreGraphics
import Foundation

/// fal.ai through its queue API: POST `https://queue.fal.run/<model>` with `Authorization: Key <key>`, poll the
/// returned `status_url` until `COMPLETED`, then GET `response_url` and download the first image.
/// Model ids are defaults that Settings can override.
public struct FalProvider: ImageProvider {
    public struct Models: Codable, Equatable, Sendable {
        /// "auto" lets `ModelCatalog.pick` choose per request.
        public var generate = ModelCatalog.auto
        public var fill = "fal-ai/flux-pro/v1/fill"
        public var removeBackground = "fal-ai/birefnet"
        public var upscale = "fal-ai/esrgan"
        /// Depth map of a picture (white = near), for relief images.
        public var depth = "fal-ai/image-preprocessors/depth-anything/v2"
        /// Image to 3D model (GLB), for model layers.
        public var model3D = ModelCatalog.auto
        public init() {}

        /// Ids that were the defaults before the catalog: saved settings holding them follow the new Auto default.
        static let oldDefaults = ["fal-ai/flux/dev", "fal-ai/trellis"]

        /// Missing ids (settings saved before a model was added) take the default.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Models()
            func pick(_ v: String?, _ def: String) -> String {
                v.map { Self.oldDefaults.contains($0) ? def : $0 } ?? def
            }
            generate = pick(try c.decodeIfPresent(String.self, forKey: .generate), d.generate)
            fill = try c.decodeIfPresent(String.self, forKey: .fill) ?? d.fill
            removeBackground = try c.decodeIfPresent(String.self, forKey: .removeBackground) ?? d.removeBackground
            upscale = try c.decodeIfPresent(String.self, forKey: .upscale) ?? d.upscale
            depth = try c.decodeIfPresent(String.self, forKey: .depth) ?? d.depth
            model3D = pick(try c.decodeIfPresent(String.self, forKey: .model3D), d.model3D)
        }
    }

    public var name: String { "fal.ai" }
    let key: String
    let models: Models
    let session: URLSession
    let base: URL
    /// Poll interval and overall limit.
    var poll: TimeInterval = 0.8
    var timeout: TimeInterval = 180

    public init(
        key: String, models: Models = Models(), session: URLSession = .shared,
        base: URL = URL(string: "https://queue.fal.run")!
    ) {
        self.key = key; self.models = models; self.session = session; self.base = base
    }

    public func generate(prompt: String, width: Int, height: Int, seed: Int?) async throws -> CGImage {
        try await generate(prompt: prompt, width: width, height: height, seed: seed, options: GenerateOptions()).image
    }

    /// Generates with `options`, resolving "auto" to a catalog model. When the model rejects the request (a 4xx
    /// other than a bad key or rate limit: wrong input shape, model gone) and `options.fallback` is on, the next
    /// model of `ModelCatalog.fallbacks` is tried, so one bad model id doesn't stop the work.
    public func generate(
        prompt: String, width: Int, height: Int, seed: Int?, options: GenerateOptions
    ) async throws -> GeneratedImage {
        let first =
            models.generate == ModelCatalog.auto
            ? ModelCatalog.pick(options.purpose, transparent: options.transparent) : models.generate
        var queue = [first]
        if options.fallback { queue += ModelCatalog.fallbacks(after: first, transparent: options.transparent) }
        var failed: [String] = []
        var lastError: Error?
        for model in queue {
            do {
                let body = Self.generateInput(
                    model: model, prompt: prompt, width: width, height: height, seed: seed, options: options)
                let img = try await run(model, body)
                return GeneratedImage(image: img, model: model, failed: failed)
            } catch let e as ImageAIError {
                guard case .http(let code, let body) = e, Self.isRequestError(code) else { throw e }
                failed.append("\(model): HTTP \(code) \(Self.reason(body))")
                lastError = e
            }
        }
        throw lastError ?? ImageAIError.failed("fal.ai: no model to try")
    }

    /// 4xx answers that another model might not give (not auth, not rate limits).
    static func isRequestError(_ code: Int) -> Bool { (400..<500).contains(code) && ![401, 403, 429].contains(code) }

    /// The first `msg` of a fal validation error, else the body's start.
    static func reason(_ body: String) -> String {
        if let v = try? JSONDecoder().decode(JSONValue.self, from: Data(body.utf8)),
            let d = v["detail"]?.array?.first, let m = d["msg"]?.string
        {
            let loc = d["loc"]?.array?.compactMap(\.string).filter { $0 != "body" }.joined(separator: ".") ?? ""
            return loc.isEmpty ? m : "\(loc): \(m)"
        }
        return String(body.prefix(120))
    }

    /// This provider with another text-to-image model (one `image_generate` call), everything else unchanged.
    public func generating(with model: String) -> FalProvider {
        var m = models
        m.generate = model
        var p = FalProvider(key: key, models: m, session: session, base: base)
        p.poll = poll; p.timeout = timeout
        return p
    }

    /// This provider with another image-to-3D model.
    public func modelling(with model: String) -> FalProvider {
        var m = models
        m.model3D = model
        var p = FalProvider(key: key, models: m, session: session, base: base)
        p.poll = poll; p.timeout = timeout
        return p
    }

    /// A fal model id: `owner/name[/variant…]`, lowercase letters, digits and `-._` (it becomes the URL path).
    public static func isModelID(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
        return parts.count >= 2 && s.count <= 120
            && parts.allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".." && String($0).unicodeScalars.allSatisfy(ok.contains)
            }
    }

    /// The request body for a text-to-image model, shaped by its catalog entry: an exact `{width, height}` fitted
    /// into the model's pixel limits, or the nearest `aspect_ratio` + `resolution`. Unknown models get the
    /// Flux-style body. The layer crops the result to the asked size, so a slightly different size is fine.
    static func generateInput(
        model: String, prompt: String, width: Int, height: Int, seed: Int?, options: GenerateOptions = GenerateOptions()
    ) -> [String: JSONValue] {
        let entry = ModelCatalog.entry(model)
        var body: [String: JSONValue] = ["prompt": .string(prompt), "num_images": 1, "output_format": "png"]
        switch entry?.sizing ?? ModelCatalog.flexibleSize {
        case .pixels(let m, let area):
            let (w, h) = ModelCatalog.fit(width, height, multiple: m, area: area)
            body["image_size"] = ["width": .number(Double(w)), "height": .number(Double(h))]
        case .aspect(let ratios, let resolution):
            body["aspect_ratio"] = .string(ModelCatalog.nearestRatio(width, height, in: ratios))
            body["resolution"] = .string(resolution)
        }
        if entry == nil || entry?.seed == true, let seed { body["seed"] = .number(Double(seed)) }
        if entry == nil { body["enable_safety_checker"] = true }
        for (k, v) in entry?.defaults ?? [:] { body[k] = v }
        if options.transparent, entry?.transparent == true { body["background"] = "transparent" }
        if let q = options.quality, entry?.defaults["quality"] != nil { body["quality"] = .string(q) }
        // The caller's own model parameters win, except the prompt.
        for (k, v) in options.extra where k != "prompt" { body[k] = v }
        return body
    }

    public func fill(image: CGImage, mask: CGImage, prompt: String, seed: Int?) async throws -> CGImage {
        var body: [String: JSONValue] = [
            "prompt": .string(prompt), "image_url": .string(try ImageData.dataURI(image)),
            "mask_url": .string(try ImageData.dataURI(mask)), "output_format": "png",
        ]
        if let seed { body["seed"] = .number(Double(seed)) }
        return try await run(models.fill, body)
    }

    public func removeBackground(image: CGImage) async throws -> CGImage {
        try await run(models.removeBackground, ["image_url": .string(try ImageData.dataURI(image))])
    }

    public func upscale(image: CGImage, factor: Int) async throws -> CGImage {
        try await run(
            models.upscale, ["image_url": .string(try ImageData.dataURI(image)), "scale": .number(Double(factor))])
    }

    public func depth(image: CGImage) async throws -> CGImage {
        try await run(models.depth, ["image_url": .string(try ImageData.dataURI(image))])
    }

    /// Image to 3D (Trellis by default): the model file the result links to (`model_mesh.url`, or a `glb` /
    /// `model_glb` field for other image-to-3D models). These take a minute or two, so the limit is longer.
    public func model3D(image: CGImage) async throws -> Data {
        var p = self
        p.timeout = max(timeout, 600)
        let model = models.model3D == ModelCatalog.auto ? ModelCatalog.defaultModel3D : models.model3D
        let result = try await p.result(model, Self.model3DInput(model: model, image: try ImageData.dataURI(image)))
        guard let url = FalProvider.modelURL(in: result) else {
            throw ImageAIError.failed("fal.ai: no model in the result")
        }
        return try await download(url)
    }

    /// The image-to-3D request: the picture in the field the model wants, plus its catalog defaults.
    static func model3DInput(model: String, image: String) -> [String: JSONValue] {
        let e = ModelCatalog.entry(model)
        var body = e?.defaults ?? [:]
        body[e?.imageField ?? "image_url"] = e?.imageList == true ? [.string(image)] : .string(image)
        return body
    }

    static func modelURL(in v: JSONValue) -> String? {
        for k in ["model_glb", "model_mesh", "pbr_model", "glb", "model", "mesh"] {
            if let u = v[k]?["url"]?.string ?? v[k]?.string { return u }
        }
        return nil
    }

    // MARK: Queue

    func request(_ url: URL, method: String = "GET", body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Key \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        r.timeoutInterval = 60
        return r
    }

    func json(_ r: URLRequest) async throws -> JSONValue {
        let (data, resp) = try await session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw code == 401 || code == 403
                ? ImageAIError.failed("fal.ai rejected the API key (HTTP \(code)) — check it in Settings ▸ AI")
                : ImageAIError.http(code, String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func run(_ model: String, _ input: [String: JSONValue]) async throws -> CGImage {
        let result = try await self.result(model, input)
        guard let urlString = FalProvider.imageURL(in: result) else {
            throw ImageAIError.failed("fal.ai: no image in the result")
        }
        return try ImageData.decode(try await download(urlString))
    }

    /// Submits `input` to `model` on the queue, waits for it, and returns the result JSON.
    func result(_ model: String, _ input: [String: JSONValue]) async throws -> JSONValue {
        let submitURL = base.appendingPathComponent(model)
        let submitted = try await json(
            request(submitURL, method: "POST", body: try JSONEncoder().encode(JSONValue.object(input))))
        guard let statusURL = submitted["status_url"]?.string.flatMap(URL.init(string:)),
            let responseURL = submitted["response_url"]?.string.flatMap(URL.init(string:))
        else { throw ImageAIError.failed("fal.ai: unexpected submit response") }
        let start = Date()
        while true {
            let st = try await json(request(statusURL))
            let status = st["status"]?.string ?? ""
            if status == "COMPLETED" {
                if let e = st["error"]?.string { throw ImageAIError.failed("fal.ai: \(e)") }
                break
            }
            if !["IN_QUEUE", "IN_PROGRESS"].contains(status) {
                throw ImageAIError.failed("fal.ai: status \(status.isEmpty ? "unknown" : status)")
            }
            if Date().timeIntervalSince(start) > timeout { throw ImageAIError.failed("fal.ai: timed out") }
            try await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
        }
        return try await json(request(responseURL))
    }

    /// The bytes behind a result URL (or an inline `data:` URI).
    func download(_ urlString: String) async throws -> Data {
        if urlString.hasPrefix("data:"), let comma = urlString.firstIndex(of: ","),
            let d = Data(base64Encoded: String(urlString[urlString.index(after: comma)...]))
        {
            return d
        }
        guard let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http" else {
            throw ImageAIError.failed("fal.ai: bad result URL")
        }
        let (data, resp) = try await session.data(from: url)
        guard ((resp as? HTTPURLResponse)?.statusCode ?? 200) < 300 else {
            throw ImageAIError.failed("fal.ai: couldn't download the result")
        }
        return data
    }

    /// `images[0].url` (generators, fill) or `image.url` (background removal, upscalers).
    static func imageURL(in v: JSONValue) -> String? {
        v["images"]?.array?.first?["url"]?.string ?? v["image"]?["url"]?.string
    }
}

/// Runs async work from synchronous code (the MCP server's request loop, the CLI). Never call on the main thread
/// of an app.
public func blocking<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) throws -> T {
    let box = ResultBox<T>()
    let sem = DispatchSemaphore(value: 0)
    Task.detached {
        do { box.result = Result<T, Error>.success(try await work()) } catch {
            box.result = Result<T, Error>.failure(error)
        }
        sem.signal()
    }
    sem.wait()
    return try box.result!.get()
}

final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
    init() {}
}
