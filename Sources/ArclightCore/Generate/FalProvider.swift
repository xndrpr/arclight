import CoreGraphics
import Foundation

/// fal.ai through its queue API: POST `https://queue.fal.run/<model>` with `Authorization: Key <key>`, poll the
/// returned `status_url` until `COMPLETED`, then GET `response_url` and download the first image.
/// Model ids are defaults that Settings (and `ARCLIGHT_FAL_MODELS`) can override.
public struct FalProvider: ImageProvider {
    public struct Models: Codable, Equatable, Sendable {
        public var generate = "fal-ai/flux/dev"
        public var fill = "fal-ai/flux-pro/v1/fill"
        public var removeBackground = "fal-ai/birefnet"
        public var upscale = "fal-ai/esrgan"
        public init() {}
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
        try await run(models.generate, Self.generateInput(model: models.generate, prompt: prompt, width: width, height: height, seed: seed))
    }

    /// This provider with another text-to-image model (one `image_generate` call), everything else unchanged.
    public func generating(with model: String) -> FalProvider {
        var m = models
        m.generate = model
        var p = FalProvider(key: key, models: m, session: session, base: base)
        p.poll = poll; p.timeout = timeout
        return p
    }

    /// A fal model id: `owner/name[/variant…]`, lowercase letters, digits and `-._` (it becomes the URL path).
    public static func isModelID(_ s: String) -> Bool {
        let parts = s.split(separator: "/", omittingEmptySubsequences: false)
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
        return parts.count >= 2 && s.count <= 120
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && String($0).unicodeScalars.allSatisfy(ok.contains) }
    }

    /// The request body for a text-to-image model. Flux-style models (the default) take an exact pixel size;
    /// GPT Image models take one of three fixed sizes, so the closest aspect is picked (the layer crops to fit).
    static func generateInput(model: String, prompt: String, width: Int, height: Int, seed: Int?) -> [String: JSONValue] {
        if model.contains("gpt-image") {
            let aspect = Double(width) / Double(max(height, 1))
            let size = aspect > 1.2 ? "1536x1024" : aspect < 1 / 1.2 ? "1024x1536" : "1024x1024"
            return ["prompt": .string(prompt), "num_images": 1, "image_size": .string(size), "output_format": "png"]
        }
        var body: [String: JSONValue] = [
            "prompt": .string(prompt), "num_images": 1,
            "image_size": ["width": .number(Double(width)), "height": .number(Double(height))],
            "enable_safety_checker": true, "output_format": "png",
        ]
        if let seed { body["seed"] = .number(Double(seed)) }
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
        let result = try await json(request(responseURL))
        guard let urlString = FalProvider.imageURL(in: result), let url = URL(string: urlString) else {
            throw ImageAIError.failed("fal.ai: no image in the result")
        }
        if urlString.hasPrefix("data:"), let comma = urlString.firstIndex(of: ","),
            let d = Data(base64Encoded: String(urlString[urlString.index(after: comma)...]))
        {
            return try ImageData.decode(d)
        }
        let (data, resp) = try await session.data(from: url)
        guard ((resp as? HTTPURLResponse)?.statusCode ?? 200) < 300 else {
            throw ImageAIError.failed("fal.ai: couldn't download the result")
        }
        return try ImageData.decode(data)
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
        do { box.result = Result<T, Error>.success(try await work()) } catch { box.result = Result<T, Error>.failure(error) }
        sem.signal()
    }
    sem.wait()
    return try box.result!.get()
}

final class ResultBox<T>: @unchecked Sendable {
    var result: Result<T, Error>?
    init() {}
}
