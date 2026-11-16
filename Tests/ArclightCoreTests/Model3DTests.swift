import CoreGraphics
import Foundation
import Testing
import simd

@testable import ArclightCore
@testable import ArclightMCP

/// Builds small binary glTF files in memory: a unit cube (8 corners, 12 triangles, no normals).
enum TestGLB {
    static func cube(
        color: [Double] = [1, 0, 0, 1], translation: [Double]? = nil, required: [String] = []
    ) -> Data {
        let p: [Float] = [-1, -1, -1, 1, -1, -1, 1, 1, -1, -1, 1, -1, -1, -1, 1, 1, -1, 1, 1, 1, 1, -1, 1, 1]
        let idx: [UInt16] = [
            0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5,
        ]
        var bin = Data()
        p.withUnsafeBytes { bin.append(contentsOf: $0) }
        let idxOffset = bin.count
        idx.withUnsafeBytes { bin.append(contentsOf: $0) }
        while bin.count % 4 != 0 { bin.append(0) }
        var node: [String: JSONValue] = ["mesh": 0]
        if let translation { node["translation"] = .array(translation.map { .number($0) }) }
        var gltf: [String: JSONValue] = [
            "asset": ["version": "2.0"], "scene": 0, "scenes": [["nodes": [0]]], "nodes": [.object(node)],
            "meshes": [["primitives": [["attributes": ["POSITION": 0], "indices": 1, "material": 0]]]],
            "materials": [["pbrMetallicRoughness": ["baseColorFactor": .array(color.map { .number($0) })]]],
            "buffers": [["byteLength": .number(Double(bin.count))]],
            "bufferViews": [
                ["buffer": 0, "byteOffset": 0, "byteLength": .number(Double(p.count * 4))],
                ["buffer": 0, "byteOffset": .number(Double(idxOffset)), "byteLength": .number(Double(idx.count * 2))],
            ],
            "accessors": [
                [
                    "bufferView": 0, "componentType": 5126, "count": 8, "type": "VEC3", "min": [-1, -1, -1],
                    "max": [1, 1, 1],
                ],
                ["bufferView": 1, "componentType": 5123, "count": .number(Double(idx.count)), "type": "SCALAR"],
            ],
        ]
        if !required.isEmpty { gltf["extensionsRequired"] = .array(required.map { .string($0) }) }
        var json = try! JSONEncoder().encode(JSONValue.object(gltf))
        while json.count % 4 != 0 { json.append(0x20) }
        var out = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        u32(0x4654_6C67); u32(2); u32(UInt32(12 + 8 + json.count + 8 + bin.count))
        u32(UInt32(json.count)); u32(0x4E4F_534A); out.append(json)
        u32(UInt32(bin.count)); u32(0x004E_4942); out.append(bin)
        return out
    }
}

@Suite struct Model3DTests {
    @Test func glbCubeLoadsWithNormalsAndColour() throws {
        let m = try GLB.parse(TestGLB.cube(color: [0, 1, 0, 1]))
        #expect(m.vertices.count == 8 && m.triangleCount == 12 && m.parts.count == 1)
        #expect(m.parts[0].color == SIMD4(0, 1, 0, 1))
        #expect(m.vertices.allSatisfy { abs(simd_length($0.normal) - 1) < 1e-4 })  // filled in
        let b = m.bounds
        #expect(b.min == SIMD3(-1, -1, -1) && b.max == SIMD3(1, 1, 1))
    }

    @Test func glbNodeTransformAndAxesConvert() throws {
        // glTF y up, z towards the viewer → Arclight y down, z into the screen.
        let m = try GLB.parse(TestGLB.cube(translation: [0, 5, 2]))
        let b = m.bounds
        #expect(abs(b.min.y - -6) < 1e-5 && abs(b.max.y - -4) < 1e-5)
        #expect(abs(b.min.z - -3) < 1e-5 && abs(b.max.z - -1) < 1e-5)
    }

    @Test func compressedAndBrokenFilesAreRefused() {
        #expect(throws: MeshError.self) {
            _ = try GLB.parse(TestGLB.cube(required: ["KHR_draco_mesh_compression"]))
        }
        #expect(throws: MeshError.self) { _ = try GLB.parse(Data("not a model".utf8)) }
        var cut = TestGLB.cube()
        cut.removeLast(40)
        #expect(throws: MeshError.self) { _ = try GLB.parse(cut) }
    }

    @Test func objLoadsThroughModelIO() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("obj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let u = dir.appendingPathComponent("tri.obj")
        try "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".write(to: u, atomically: true, encoding: .utf8)
        let m = try Mesh.load(u)
        #expect(m.triangleCount == 1)
        #expect(abs(m.bounds.min.y - -1) < 1e-5)  // y flipped like glTF
    }

    @Test(.requiresMetal) func modelLayerRendersSolidAndHidesWhatIsBehind() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try TestGLB.cube(color: [1, 0, 0, 1]).write(to: dir.appendingPathComponent("cube.glb"))
        var s = Scene(id: "s", duration: 1)
        s.background = .value("#000000")
        s.nodes = [
            Node(
                id: "card", type: "shape",
                props: [
                    "x": 100, "y": 100, "z": 400, "width": 400, "height": 400, "fill": "#0000FF", "3d": true,
                ].mapValues { .value($0) }),
            Node(
                id: "m", type: "model",
                props: ["src": "cube.glb", "x": 100, "y": 100, "z": 0, "size": 80, "shade": 0].mapValues { .value($0) }
            ),
        ]
        let img = try Renderer().image(scene: s, project: Project(name: "t", size: [200, 200]), assets: dir, time: 0)
        let data = CFDataGetBytePtr(img.dataProvider!.data!)!
        func px(_ x: Int, _ y: Int) -> (r: UInt8, b: UInt8) {
            let o = y * img.bytesPerRow + x * 4
            return (data[o + 2], data[o])
        }
        #expect(px(100, 100).r > 200 && px(100, 100).b < 30)  // the cube, in front
        // The card (400 px at z 400, ~160 px on screen) shows around the cube.
        #expect(px(100, 30).b > 150 && px(100, 30).r < 30)
        // The fit: an 80 px cube centred on the 1:1 plane is ~94 px across at its near face, so it ends near y 147.
        #expect(px(100, 160).r < 30 && px(100, 160).b > 150)
    }

    @Test(.requiresMetal) func modelGenerateMakesAndPlacesAModel() throws {
        let tp = try TempProject("model-gen", scenes: [Scene(id: "s", duration: 2)])
        defer { tp.remove() }
        let server = MCPServer(projectPath: tp.url.path)
        let fake = FakeProvider()
        server.imageProviderOverride = fake
        func run(_ a: [String: JSONValue]) throws -> [JSONValue] {
            try server.tools.first { $0.name == "model_generate" }!.run(a)
        }
        let out = try run(["prompt": "mannequin hand", "scene": "s", "z": 300, "material": "clay"])
        let txt = out.compactMap { $0.object?["text"]?.string }.joined()
        #expect(txt.contains("mannequin-hand.glb") && txt.contains("12 triangles"))
        #expect(out.contains { $0.object?["type"]?.string == "image" })  // turntable sheet
        #expect(fake.calls.contains { $0.hasPrefix("generate 1024x1024 mannequin hand, a single object") })
        #expect(fake.calls.contains("model3D"))
        let st = try ProjectStore(url: tp.url)
        let n = try #require(st.scenes["s"]?.nodes.first { $0.type == "model" })
        #expect(n.props["src"] == .value("mannequin-hand.glb") && n.props["material"] == .value("clay"))
        #expect(
            FileManager.default.fileExists(atPath: st.assetsURL.appendingPathComponent("mannequin-hand-ref.png").path))
        #expect(throws: (any Error).self) { try run(["scene": "s"]) }
    }
}
