import CoreGraphics
import Foundation
import Testing
import simd

@testable import ArclightCore
@testable import ArclightMCP

/// Builds a .glb from float accessors: `add` returns the accessor index.
struct GLTFBuilder {
    var bin = Data()
    var views: [JSONValue] = []
    var accessors: [JSONValue] = []
    var json: [String: JSONValue] = ["asset": ["version": "2.0"], "scene": 0]

    mutating func add(_ v: [Float], _ type: String) -> JSONValue {
        let comps = ["SCALAR": 1, "VEC3": 3, "VEC4": 4, "MAT4": 16][type]!
        while bin.count % 4 != 0 { bin.append(0) }
        let off = bin.count
        v.withUnsafeBytes { bin.append(contentsOf: $0) }
        views.append(["buffer": 0, "byteOffset": .number(Double(off)), "byteLength": .number(Double(v.count * 4))])
        var a: [String: JSONValue] = [
            "bufferView": .number(Double(views.count - 1)), "componentType": 5126,
            "count": .number(Double(v.count / comps)), "type": .string(type),
        ]
        if type == "SCALAR" {
            a["min"] = [.number(Double(v.min() ?? 0))]
            a["max"] = [.number(Double(v.max() ?? 0))]
        }
        accessors.append(.object(a))
        return .number(Double(accessors.count - 1))
    }

    func glb() -> Data {
        var g = json
        g["buffers"] = [["byteLength": .number(Double(bin.count))]]
        g["bufferViews"] = .array(views)
        g["accessors"] = .array(accessors)
        var j = try! JSONEncoder().encode(JSONValue.object(g))
        while j.count % 4 != 0 { j.append(0x20) }
        var b = bin
        while b.count % 4 != 0 { b.append(0) }
        var out = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        u32(0x4654_6C67); u32(2); u32(UInt32(12 + 8 + j.count + 8 + b.count))
        u32(UInt32(j.count)); u32(0x4E4F_534A); out.append(j)
        u32(UInt32(b.count)); u32(0x004E_4942); out.append(b)
        return out
    }

    /// A unit cube on node 0 that slides 2 units along x over 1 s (a "slide" clip).
    static func slidingCube() -> Data {
        var g = GLTFBuilder()
        let c: [Float] = [-1, -1, -1, 1, -1, -1, 1, 1, -1, -1, 1, -1, -1, -1, 1, 1, -1, 1, 1, 1, 1, -1, 1, 1]
        let tris: [Int] = [
            0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5,
        ]
        let pos = g.add(tris.flatMap { [c[$0 * 3], c[$0 * 3 + 1], c[$0 * 3 + 2]] }, "VEC3")
        let times = g.add([0, 1], "SCALAR")
        let moves = g.add([0, 0, 0, 2, 0, 0], "VEC3")
        g.json["scenes"] = [["nodes": [0]]]
        g.json["nodes"] = [["mesh": 0]]
        g.json["meshes"] = [["primitives": [["attributes": ["POSITION": pos], "material": 0]]]]
        g.json["materials"] = [["pbrMetallicRoughness": ["baseColorFactor": [1, 0, 0, 1]]]]
        g.json["animations"] = [
            [
                "name": "slide", "samplers": [["input": times, "output": moves]],
                "channels": [["sampler": 0, "target": ["node": 0, "path": "translation"]]],
            ]
        ]
        return g.glb()
    }
}

@Suite struct ModelAnimationTests {
    /// glTF → Arclight space (y and z flip).
    func arc(_ x: Float, _ y: Float, _ z: Float) -> SIMD3<Float> { SIMD3(x, -y, -z) }
    func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Bool { simd_distance(a, b) < 1e-4 }

    @Test func bonesBendTheMesh() throws {
        // Two bones: the root at the origin, a child 1 up that turns 90° about z over a second.
        var g = GLTFBuilder()
        let pos = g.add([0, 0, 0, 0, 2, 0, 0.1, 0, 0], "VEC3")
        let joints = g.add([0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0], "VEC4")
        let weights = g.add([1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0], "VEC4")
        let inv = g.add(
            [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1] + [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, -1, 0, 1], "MAT4"
        )
        let times = g.add([0, 1], "SCALAR")
        let s = sin(Float.pi / 4)
        let turns = g.add([0, 0, 0, 1, 0, 0, s, s], "VEC4")
        g.json["scenes"] = [["nodes": [0, 2]]]
        g.json["nodes"] = [["children": [1]], ["translation": [0, 1, 0]], ["mesh": 0, "skin": 0]]
        g.json["skins"] = [["joints": [0, 1], "inverseBindMatrices": inv]]
        g.json["meshes"] = [
            ["primitives": [["attributes": ["POSITION": pos, "JOINTS_0": joints, "WEIGHTS_0": weights]]]]
        ]
        g.json["animations"] = [
            [
                "name": "Bend", "samplers": [["input": times, "output": turns]],
                "channels": [["sampler": 0, "target": ["node": 1, "path": "rotation"]]],
            ]
        ]
        let m = try GLB.parse(g.glb())
        let rig = try #require(m.rig)
        #expect(rig.animated && rig.clips.map(\.name) == ["Bend"] && rig.clips[0].duration == 1)
        #expect(near(m.vertices[1].position, arc(0, 2, 0)))  // first frame
        let end = rig.pose(clip: 0, time: 1).positions
        #expect(near(end[1], arc(-1, 1, 0)) && near(end[0], arc(0, 0, 0)))
        let mid = rig.pose(clip: 0, time: 0.5).positions
        #expect(near(mid[1], arc(-sin(.pi / 4), 1 + cos(.pi / 4), 0)))  // slerp halfway: 45°
        #expect(near(rig.pose(clip: nil, time: 1).positions[1], arc(0, 2, 0)))  // rest
    }

    @Test func shapeKeysBlendByWeight() throws {
        var g = GLTFBuilder()
        let pos = g.add([0, 0, 0, 1, 0, 0, 0, 1, 0], "VEC3")
        let delta = g.add([1, 0, 0, 0, 0, 0, 0, 0, 0], "VEC3")
        let times = g.add([0, 2], "SCALAR")
        let w = g.add([0, 1], "SCALAR")
        g.json["scenes"] = [["nodes": [0]]]
        g.json["nodes"] = [["mesh": 0]]
        g.json["meshes"] = [["primitives": [["attributes": ["POSITION": pos], "targets": [["POSITION": delta]]]]]]
        g.json["animations"] = [
            [
                "samplers": [["input": times, "output": w]],
                "channels": [["sampler": 0, "target": ["node": 0, "path": "weights"]]],
            ]
        ]
        let rig = try #require(try GLB.parse(g.glb()).rig)
        #expect(rig.clips[0].name == "clip 0")
        #expect(near(rig.pose(clip: 0, time: 1).positions[0], arc(0.5, 0, 0)))
        #expect(near(rig.pose(clip: 0, time: 2).positions[0], arc(1, 0, 0)))
    }

    @Test func clipsAreFoundByIndexOrName() throws {
        let rig = try #require(try GLB.parse(GLTFBuilder.slidingCube()).rig)
        #expect(rig.clipIndex("") == 0 && rig.clipIndex("SLIDE") == 0 && rig.clipIndex("0") == 0)
        #expect(rig.clipIndex("none") == nil && rig.clipIndex("walk") == nil)
        // A still model has no rig at all.
        #expect(try GLB.parse(TestGLB.cube()).rig == nil)
    }

    @Test func stepAndCubicKeys() {
        let step = Rig.Channel(
            node: 0, path: .translation, times: [0, 1], values: [0, 0, 0, 4, 0, 0], comps: 3, interpolation: .step)
        #expect(Rig.sample(step, at: 0.9) == [0, 0, 0] && Rig.sample(step, at: 1) == [4, 0, 0])
        // Cubic with flat tangents: eases, passing the middle at half time.
        let cubic = Rig.Channel(
            node: 0, path: .scale, times: [0, 1], values: [0, 1, 0, 0, 3, 0], comps: 1, interpolation: .cubic)
        #expect(abs(Rig.sample(cubic, at: 0.5)[0] - 2) < 1e-5 && Rig.sample(cubic, at: 0.25)[0] < 1.5)
    }

    @Test(.requiresMetal) func modelLayerPlaysItsClip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try GLTFBuilder.slidingCube().write(to: dir.appendingPathComponent("slide.glb"))
        func red(at time: Double, _ x: Int, extra: [String: JSONValue] = [:]) throws -> Bool {
            var s = Scene(id: "s", duration: 4)
            s.background = .value("#000000")
            var props: [String: JSONValue] = ["src": "slide.glb", "x": 100, "y": 100, "z": 0, "size": 80, "shade": 0]
            props.merge(extra) { $1 }
            s.nodes = [Node(id: "m", type: "model", props: props.mapValues { .value($0) })]
            let img = try Renderer().image(
                scene: s, project: Project(name: "t", size: [200, 200]), assets: dir, time: time)
            let data = CFDataGetBytePtr(img.dataProvider!.data!)!
            return data[100 * img.bytesPerRow + x * 4 + 2] > 150
        }
        // The cube is fitted on its first frame (2 units → 80 px), then slides 2 units → ~80 px right over 1 s.
        #expect(try red(at: 0, 100))
        #expect(try red(at: 0.5, 140) && !(try red(at: 0.5, 70)))
        #expect(try red(at: 1.5, 140))  // loops
        #expect(try red(at: 0.5, 100, extra: ["clip": "none"]) && !(try red(at: 0.5, 150, extra: ["clip": "none"])))
        #expect(try red(at: 0, 140, extra: ["clipOffset": 0.5]))  // its own phase
        #expect(try red(at: 3, 140, extra: ["clipTime": 0.5]))  // driven directly
    }

    @Test func assetImportListsClips() throws {
        let tp = try TempProject("anim-import", scenes: [Scene(id: "s", duration: 2)])
        defer { tp.remove() }
        let src = tp.url.appendingPathComponent("crawl.glb")
        try GLTFBuilder.slidingCube().write(to: src)
        let server = MCPServer(projectPath: tp.url.path)
        func run(_ path: String) throws -> String {
            try server.tools.first { $0.name == "asset_import" }!.run(["path": .string(path)])
                .compactMap { $0.object?["text"]?.string }.joined()
        }
        let txt = try run(src.path)
        #expect(txt.contains("src: crawl.glb") && txt.contains("0: slide (1 s)"))
        #expect(try run("crawl.glb").contains("slide"))  // again, by its name in assets/
        try TestGLB.cube().write(to: src)
        #expect(try run(src.path).contains("no animation"))
    }

    @Test func blendNeedsBlender() throws {
        let args = BlendConverter.arguments(
            blend: URL(fileURLWithPath: "/a/b c.blend"), out: URL(fileURLWithPath: "/t/o.glb"))
        #expect(args.first == "-b" && args[1] == "/a/b c.blend" && args.suffix(2) == ["--", "/t/o.glb"])
        if BlendConverter.locate() == nil {
            #expect(throws: MeshError.self) {
                _ = try BlendConverter.convert(URL(fileURLWithPath: "/a.blend"), to: URL(fileURLWithPath: "/tmp/x.glb"))
            }
        }
    }
}
