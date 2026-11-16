import CoreGraphics
import Foundation
import Testing

@testable import ArclightCore

/// Serves a tiny Poly Haven: two models, a texture, and one glTF with a separate buffer and image.
final class LibraryMock: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var files: [String: Data] = [:]
    nonisolated(unsafe) static var requests: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let u = request.url!
        let key = u.path + (u.query.map { "?" + $0 } ?? "")
        LibraryMock.requests.append(key)
        let body = LibraryMock.files[key]
        client?.urlProtocol(
            self,
            didReceive: HTTPURLResponse(
                url: u, statusCode: body == nil ? 404 : 200, httpVersion: nil, headerFields: nil)!,
            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct AssetLibraryTests {
    /// The cube from `TestGLB` split into a .gltf, a .bin and a texture, as Poly Haven ships models.
    static func splitCube() throws -> (gltf: Data, bin: Data, png: Data) {
        let glb = TestGLB.cube()
        let jsonLen = Int(glb.u32(12))
        let json = glb.subdata(in: 20..<(20 + jsonLen))
        let binStart = 20 + jsonLen + 8
        let bin = glb.subdata(in: binStart..<glb.count)
        var g = try JSONDecoder().decode(JSONValue.self, from: json).object!
        g["buffers"] = [["byteLength": .number(Double(bin.count)), "uri": "cube.bin"]]
        g["images"] = [["uri": "textures/cube%20diff.png"]]
        g["textures"] = [["source": 0]]
        let ctx = ImageData.context(4, 4)!
        ctx.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1));
        ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return (try JSONEncoder().encode(JSONValue.object(g)), bin, ImageData.png(ctx.makeImage()!)!)
    }

    private func library() throws -> AssetLibrary {
        let (gltf, bin, png) = try Self.splitCube()
        LibraryMock.requests = []
        LibraryMock.files = [
            "/assets?type=models": Data(
                #"{"cube_01":{"name":"Cube 01","categories":["props"],"tags":["box","crate"],"polycount":6,"dimensions":[1000,500,250]},"Chandelier_01":{"name":"Chandelier 01","categories":["lighting"],"tags":["ceiling"]},"hand_plane":{"name":"Hand Plane","categories":["tools"],"tags":["carpentry"]}}"#
                    .utf8),
            "/assets?type=textures": Data(
                #"{"oak_planks":{"name":"Oak Planks","categories":["wood"],"tags":["floor"]}}"#.utf8),
            "/files/cube_01": Data(
                #"{"gltf":{"1k":{"gltf":{"url":"https://dl.test/cube.gltf","include":{"cube.bin":{"url":"https://dl.test/cube.bin"},"textures/cube diff.png":{"url":"https://dl.test/diff.png"},"textures/unused_nor.png":{"url":"https://dl.test/nor.png"}}}}}}"#
                    .utf8),
            "/files/oak_planks": Data(#"{"Diffuse":{"1k":{"jpg":{"url":"https://dl.test/oak.jpg"}}}}"#.utf8),
            "/cube.gltf": gltf, "/cube.bin": bin, "/diff.png": png,
            "/oak.jpg": ImageData.encode(ImageData.context(8, 8)!.makeImage()!, type: "public.jpeg")!,
        ]
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [LibraryMock.self]
        return AssetLibrary(session: URLSession(configuration: c), api: URL(string: "https://api.test")!)
    }

    @Test func searchMatchesWholeWordsBestFirst() async throws {
        let lib = try library()
        let hand = try await lib.search("hand", kind: .model)
        #expect(hand.map(\.id) == ["hand_plane"])  // not Chandelier
        let crates = try await lib.search("wooden crates", kind: .model)
        #expect(crates.first?.id == "cube_01" && crates.first?.sizeCM == [100, 50, 25])
        #expect(try await lib.search("oak floor", kind: .texture).map(\.id) == ["oak_planks"])
        #expect(try await lib.search("caterpillar", kind: .model).isEmpty)
    }

    @Test func importPacksTheGLTFIntoOneReadableGLB() async throws {
        let lib = try library()
        let tp = try TempProject("library")
        let name = try await lib.importModel("cube_01", store: tp.store)
        #expect(name == "cube-01.glb")
        let glb = try Data(contentsOf: tp.store.assetsURL.appendingPathComponent(name))
        let mesh = try GLB.parse(glb)
        #expect(mesh.triangleCount == 12)
        // Only the files the glTF uses were downloaded; the image now lives inside the .glb.
        #expect(!LibraryMock.requests.contains("/nor.png") && LibraryMock.requests.contains("/diff.png"))
        let json = try JSONDecoder().decode(JSONValue.self, from: glb.subdata(in: 20..<(20 + Int(glb.u32(12)))))
        #expect(json["images"]?.array?.first?["uri"] == nil && json["images"]?.array?.first?["mimeType"] == "image/png")
        #expect(json["buffers"]?.array?.count == 1 && json["buffers"]?.array?.first?["uri"] == nil)

        let tex = try await lib.importTexture("oak_planks", store: tp.store)
        #expect(tex == "oak-planks.jpg")
        await #expect(throws: ImageAIError.self) { _ = try await lib.importModel("missing", store: tp.store) }
    }
}
