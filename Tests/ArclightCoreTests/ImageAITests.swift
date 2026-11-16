import CoreGraphics
import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightMCP

/// A stand-in for fal.ai: solid-colour results of the requested size, and a record of what was asked.
final class FakeProvider: ImageProvider, @unchecked Sendable {
    var name: String { "fake" }
    var calls: [String] = []
    var lastMask: CGImage?

    func solid(_ w: Int, _ h: Int, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat, alpha: CGFloat = 1) -> CGImage {
        let ctx = ImageData.context(w, h)!
        ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: alpha))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    func generate(prompt: String, width: Int, height: Int, seed: Int?) async throws -> CGImage {
        calls.append("generate \(width)x\(height) \(prompt)"); return solid(width, height, 1, 0, 0)
    }
    func fill(image: CGImage, mask: CGImage, prompt: String, seed: Int?) async throws -> CGImage {
        calls.append("fill \(image.width)x\(image.height)"); lastMask = mask
        return solid(image.width, image.height, 0, 1, 0)
    }
    func removeBackground(image: CGImage) async throws -> CGImage {
        calls.append("cutout"); return solid(image.width, image.height, 0, 0, 1, alpha: 0.5)
    }
    func upscale(image: CGImage, factor: Int) async throws -> CGImage {
        calls.append("upscale \(factor)"); return solid(image.width * factor, image.height * factor, 1, 1, 0)
    }
}

/// Serves canned fal queue responses: submit → status (IN_PROGRESS, then COMPLETED) → result → image bytes.
final class FalMock: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var log: [String] = []
    nonisolated(unsafe) static var statuses: [String] = []
    nonisolated(unsafe) static var submitCode = 200
    nonisolated(unsafe) static var png = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let u = request.url!.absoluteString
        FalMock.log.append(
            "\(request.httpMethod ?? "GET") \(u) \(request.value(forHTTPHeaderField: "Authorization") ?? "")")
        func reply(_ code: Int, _ body: Data, _ type: String = "application/json") {
            client?.urlProtocol(
                self,
                didReceive: HTTPURLResponse(
                    url: request.url!, statusCode: code, httpVersion: nil, headerFields: ["Content-Type": type])!,
                cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
        if request.httpMethod == "POST" {
            reply(
                FalMock.submitCode,
                Data(
                    #"{"request_id":"r1","status_url":"https://queue.test/fal-ai/x/requests/r1/status","response_url":"https://queue.test/fal-ai/x/requests/r1"}"#
                        .utf8))
        } else if u.hasSuffix("/status") {
            let s = FalMock.statuses.isEmpty ? "COMPLETED" : FalMock.statuses.removeFirst()
            reply(200, Data(#"{"status":"\#(s)"}"#.utf8))
        } else if u.hasSuffix("/r1") {
            reply(200, Data(#"{"images":[{"url":"https://cdn.test/out.png","content_type":"image/png"}]}"#.utf8))
        } else {
            reply(200, FalMock.png, "image/png")
        }
    }
}

@Suite(.serialized) struct ImageAITests {
    private func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FalMock.self]
        return URLSession(configuration: c)
    }

    private func project() throws -> (TempProject, ArclightCore.Scene) {
        let tp = try TempProject("image-ai")
        let p = FakeProvider().solid(400, 200, 0.2, 0.4, 0.8)
        try ImageData.png(p)!.write(to: tp.store.assetsURL.appendingPathComponent("photo.png"))
        var s = ArclightCore.Scene(id: "s", duration: 1)
        s.nodes = [
            Node(id: "photo", type: "image", props: ["src": .value("photo.png"), "x": .value(300), "y": .value(200)])
        ]
        try tp.store.save(scene: s)
        return (tp, s)
    }

    @Test func falQueueSubmitsPollsAndDownloads() async throws {
        FalMock.log = []; FalMock.statuses = ["IN_QUEUE", "IN_PROGRESS"]; FalMock.submitCode = 200
        FalMock.png = ImageData.png(FakeProvider().solid(64, 32, 1, 0, 0))!
        var fal = FalProvider(key: "k123", session: session(), base: URL(string: "https://queue.test")!)
        fal.poll = 0.01
        let img = try await fal.generate(prompt: "a cat", width: 64, height: 32, seed: 1)
        #expect(img.width == 64 && img.height == 32)
        #expect(FalMock.log.first == "POST https://queue.test/fal-ai/flux/dev Key k123")
        #expect(FalMock.log.filter { $0.contains("/status") }.count == 3)  // queue, progress, completed
        #expect(FalMock.log.last?.hasPrefix("GET https://cdn.test/out.png") == true)
    }

    @Test func generateModelCanBeChosenPerCall() async throws {
        FalMock.log = []; FalMock.statuses = []; FalMock.submitCode = 200
        FalMock.png = ImageData.png(FakeProvider().solid(64, 32, 1, 0, 0))!
        var fal = FalProvider(key: "k", session: session(), base: URL(string: "https://queue.test")!)
        fal.poll = 0.01
        _ = try await fal.generating(with: "fal-ai/flux-pro/v1.1").generate(
            prompt: "x", width: 64, height: 32, seed: nil)
        #expect(FalMock.log.first == "POST https://queue.test/fal-ai/flux-pro/v1.1 Key k")
        #expect(fal.models.generate == "fal-ai/flux/dev")  // the original is unchanged

        let gpt = FalProvider.generateInput(
            model: "fal-ai/gpt-image-1/text-to-image", prompt: "x", width: 1280, height: 720, seed: 3)
        #expect(gpt["image_size"] == "1536x1024" && gpt["seed"] == nil && gpt["enable_safety_checker"] == nil)
        #expect(
            FalProvider.generateInput(model: "fal-ai/gpt-image-1", prompt: "x", width: 720, height: 1280, seed: nil)[
                "image_size"] == "1024x1536")
        let flux = FalProvider.generateInput(model: "fal-ai/flux/dev", prompt: "x", width: 1280, height: 720, seed: 3)
        #expect(flux["image_size"]?["width"] == 1280 && flux["seed"] == 3)

        #expect(FalProvider.isModelID("fal-ai/flux-pro/v1.1-ultra"))
        #expect(
            !FalProvider.isModelID("flux") && !FalProvider.isModelID("fal-ai/../x") && !FalProvider.isModelID("a/b?c=1")
        )
    }

    @Test func falReportsRejectedKeysAndFailures() async throws {
        FalMock.submitCode = 401; FalMock.statuses = []
        let fal = FalProvider(key: "bad", session: session(), base: URL(string: "https://queue.test")!)
        await #expect(throws: ImageAIError.self) {
            _ = try await fal.generate(prompt: "x", width: 64, height: 64, seed: nil)
        }
        FalMock.submitCode = 200; FalMock.statuses = ["FAILED"]
        await #expect(throws: ImageAIError.self) {
            _ = try await fal.generate(prompt: "x", width: 64, height: 64, seed: nil)
        }
        #expect(FalProvider.imageURL(in: ["image": ["url": "u"]]) == "u")
    }

    @Test func keysComeFromEnvironmentThenKeychain() throws {
        let saved = KeychainStore.backend
        defer { KeychainStore.backend = saved }
        let mem = KeychainStore.MemoryBackend()
        KeychainStore.backend = mem
        #expect(KeychainStore.falKey(environment: [:]) == nil)
        try KeychainStore.setFalKey("  stored  ")
        #expect(KeychainStore.falKey(environment: [:]) == "stored")
        #expect(KeychainStore.falKey(environment: ["FAL_KEY": "env"]) == "env")
        try KeychainStore.setFalKey("")
        #expect(mem.values["fal"] == nil)
    }

    @Test func operationsWriteAssetsAndReturnLayerOps() async throws {
        let (tp, s) = try project()
        defer { tp.remove() }
        let fake = FakeProvider()
        let cut = try await ImageAI.removeBackground(layer: "photo", in: s, store: tp.store, engine: .fal, fal: fake)
        #expect(cut.asset == "photo-cutout.png")
        #expect(FileManager.default.fileExists(atPath: tp.store.assetsURL.appendingPathComponent(cut.asset).path))
        var after = try SceneOps.apply(cut.ops, to: s).scene
        #expect(after.node("photo")?.props["src"] == .value("photo-cutout.png"))
        #expect(after.node("photo")?.props["width"] == .value(400))  // drawn size kept

        let up = try await ImageAI.upscale(layer: "photo", in: after, store: tp.store, factor: 2, provider: fake)
        #expect(up.asset == "photo-cutout-x2.png")
        after = try SceneOps.apply(up.ops, to: after).scene
        #expect(after.node("photo")?.props["width"] == .value(400))

        let ex = try await ImageAI.expand(
            layer: "photo", in: s, store: tp.store, left: 100, top: 0, right: 0, bottom: 0, prompt: "", provider: fake)
        let e = try SceneOps.apply(ex.ops, to: s).scene.node("photo")!
        #expect(e.props["width"] == .value(500) && e.props["height"] == .value(200))
        #expect(e.props["x"] == .value(250))  // grew left: centre moves left by half the new width
        #expect(fake.calls.contains("fill 500x200"))

        let gen = try await ImageAI.generate(
            prompt: "Neon city at night!", width: 1280, height: 720, in: s, project: tp.store.project, store: tp.store,
            provider: fake, place: true)
        #expect(gen.asset == "gen-neon-city-at-night.png")
        #expect(fake.calls.contains("generate 1280x720 Neon city at night!"))
        let g = try SceneOps.apply(gen.ops, to: s).scene
        #expect(g.node(gen.layer)?.props["width"] == .value(1280))
        #expect(ImageAI.history(tp.store).map(\.op) == ["remove_bg", "upscale", "expand", "generate"])
    }

    @Test(.requiresMetal) func fillRendersSendsAMaskAndAddsALayer() async throws {
        let (tp, s) = try project()
        defer { tp.remove() }
        let fake = FakeProvider()
        var p = tp.store.project; p.size = [640, 360]
        let r = try await ImageAI.fill(
            rect: CGRect(x: 100, y: 100, width: 80, height: 40), prompt: "a red balloon", in: s, project: p,
            store: tp.store, renderer: try Renderer(), provider: fake, above: "photo")
        let out = try SceneOps.apply(r.ops, to: s).scene
        let n = try #require(out.node(r.layer))
        #expect(n.props["x"] == .value(140) && n.props["y"] == .value(120) && n.props["width"] == .value(80))
        #expect(out.nodes.map(\.id) == ["photo", r.layer])
        let mask = try #require(fake.lastMask)
        // The window is the selection plus context around it; the mask is white only over the selection.
        #expect(mask.width == 160 && mask.height == 120)
        await #expect(throws: ImageAIError.self) {
            _ = try await ImageAI.fill(
                rect: CGRect(x: 0, y: 0, width: 4, height: 4), prompt: "x", in: s, project: p, store: tp.store,
                renderer: try Renderer(), provider: fake)
        }
    }

    @Test(.requiresMetal) func mcpToolsUseTheProviderAndSaveRevertibleEdits() throws {
        let (tp, _) = try project()
        defer { tp.remove() }
        var pv = ArclightCore.Thumbnail(id: "t", artboards: [Artboard(id: "a")])
        pv.artboards[0].nodes = [
            Node(id: "photo", type: "image", props: ["src": .value("photo.png"), "x": .value(640), "y": .value(360)])
        ]
        try tp.store.save(thumbnail: pv)
        let server = MCPServer(projectPath: tp.url.path)
        func run(_ n: String, _ a: [String: JSONValue]) throws -> String {
            try server.tools.first { $0.name == n }!.run(a).compactMap { $0.object?["text"]?.string }.joined()
        }
        // Without a key (and no override) the fal tools explain how to turn them on.
        let saved = KeychainStore.backend
        KeychainStore.backend = KeychainStore.MemoryBackend()
        defer { KeychainStore.backend = saved }
        if ProcessInfo.processInfo.environment["FAL_KEY"] == nil
            && ProcessInfo.processInfo.environment["ARCLIGHT_FAL_KEY"] == nil
        {
            #expect(throws: (any Error).self) { try run("image_upscale", ["thumbnail": "t", "layer": "photo"]) }
            #expect(try run("image_status", [:]).contains("fal.ai: off"))
        }
        server.imageProviderOverride = FakeProvider()
        let out = try run("image_upscale", ["thumbnail": "t", "layer": "photo", "factor": 3])
        #expect(out.contains("photo-x3.png") && out.contains("saved thumbnail t rev 2"))
        let gen = try run("image_generate", ["prompt": "sunset", "thumbnail": "t", "width": 512, "height": 512])
        #expect(gen.contains("gen-sunset.png"))
        #expect(throws: (any Error).self) { try run("image_generate", ["prompt": "x", "model": "../etc"]) }
        _ = try run("image_generate", ["prompt": "dusk", "model": "fal-ai/flux-pro/v1.1"])  // fake provider ignores it
        let st = try ProjectStore(url: tp.url)
        #expect(st.thumbnails["t"]?.artboards[0].nodes.count == 2)
        #expect(try run("image_status", [:]).contains("fal.ai: on"))
        // Scenes work too.
        _ = try run("image_remove_bg", ["scene": "s", "layer": "photo", "engine": "fal"])
        #expect(try ProjectStore(url: tp.url).scenes["s"]?.node("photo")?.props["src"] == .value("photo-cutout.png"))
    }

    /// On-device cut-out of a real photo (one of macOS's account pictures), through the same path the editor uses.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: "/Library/User Pictures/Animals/Eagle.heic")))
    func localBackgroundRemovalMakesTheBackgroundTransparent() async throws {
        let tp = try TempProject("cutout")
        defer { tp.remove() }
        let name = try tp.store.importAsset(from: URL(fileURLWithPath: "/Library/User Pictures/Animals/Eagle.heic"))
        var s = ArclightCore.Scene(id: "s", duration: 1)
        s.nodes = [Node(id: "bird", type: "image", props: ["src": .value(.string(name))])]
        let r = try await ImageAI.removeBackground(layer: "bird", in: s, store: tp.store, engine: .local)
        let img = try ImageData.load(tp.store.assetsURL.appendingPathComponent(r.asset))
        let ctx = try #require(ImageData.context(img.width, img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        let d = try #require(ctx.data?.assumingMemoryBound(to: UInt8.self))
        let corner = d[3]  // top-left alpha: sky, removed
        let centre = d[(img.height / 2) * ctx.bytesPerRow + (img.width / 2) * 4 + 3]
        #expect(corner < 20 && centre > 200, "corner \(corner) centre \(centre)")
    }

    @Test func outpaintPaddingAndMasks() throws {
        let img = FakeProvider().solid(100, 50, 1, 0, 0)
        let (canvas, mask) = try #require(ImageData.padded(img, left: 10, top: 0, right: 30, bottom: 20))
        #expect(canvas.width == 140 && canvas.height == 70)
        #expect(mask.width == 140)
        let m = try #require(ImageData.mask(width: 20, height: 10, white: CGRect(x: 5, y: 2, width: 4, height: 4)))
        #expect(m.width == 20 && m.height == 10)
        #expect(ImageAI.slug("  Hello, World!! again and more ") == "hello-world-again-and")
    }
}
