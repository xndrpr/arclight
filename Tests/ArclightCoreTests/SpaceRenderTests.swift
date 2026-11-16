import CoreGraphics
import Foundation
import Testing

@testable import ArclightCore

/// Depth-correct 3D layers: the world pass hides what is behind a solid 3D layer, whatever the list order.
@Suite struct SpaceRenderTests {
    func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let data = CFDataGetBytePtr(img.dataProvider!.data!)!
        let o = y * img.bytesPerRow + x * 4
        return (data[o + 2], data[o + 1], data[o])  // BGRA
    }

    func square(_ id: String, _ color: String, z: Double, size: Double = 80) -> Node {
        Node(
            id: id, type: "shape",
            props: [
                "x": .value(100), "y": .value(100), "z": .value(.number(z)), "width": .value(.number(size)),
                "height": .value(.number(size)), "fill": .value(.string(color)), "3d": .value(true),
            ])
    }

    func render(_ nodes: [Node], camera: JSONValue? = nil) throws -> CGImage {
        var s = Scene(id: "s", duration: 1)
        s.background = .value("#000000")
        if let camera { s.camera = .value(camera) }
        s.nodes = nodes
        return try Renderer().image(scene: s, project: Project(name: "t", size: [200, 200]), assets: nil, time: 0)
    }

    @Test(.requiresMetal) func nearerLayerHidesALaterLayerBehindIt() throws {
        // Blue at z 0 is nearer the default camera (it looks along +z) than red at z 300, listed after it.
        let img = try render([square("blue", "#0000FF", z: 0), square("red", "#FF0000", z: 300, size: 400)])
        let c = pixel(img, 100, 100)
        #expect(c.b > 200 && c.r < 30)
        // Outside the blue square the larger, farther red one still shows (400 px at z 300 is ~190 px on screen).
        let edge = pixel(img, 100, 40)
        #expect(edge.r > 150 && edge.b < 30)
    }

    @Test(.requiresMetal) func layersOnOnePlaneKeepListOrder() throws {
        let img = try render([square("panel", "#0000FF", z: 0), square("label", "#00FF00", z: 0, size: 30)])
        let c = pixel(img, 100, 100)
        #expect(c.g > 200 && c.b < 30)
    }

    @Test(.requiresMetal) func cameraOnTheOtherSideFlipsTheOrder() throws {
        // Looking back along -z from z 1500: red (z 300) is now in front of blue (z 0).
        let cam: JSONValue = ["position": [100, 100, 1500], "target": [100, 100, 0], "fov": 40]
        let img = try render(
            [square("blue", "#0000FF", z: 0), square("red", "#FF0000", z: 300, size: 160)], camera: cam)
        let c = pixel(img, 100, 100)
        #expect(c.r > 150 && c.b < 30)
    }

    func box(_ props: [String: JSONValue]) -> Node {
        var p: [String: JSONValue] = [
            "x": 100, "y": 100, "back": ["color": "#FF0000"], "top": ["color": "#0000FF"],
            "front": ["color": "#00FF00"], "shade": 0,
        ]
        for (k, v) in props { p[k] = v }
        return Node(id: "b", type: "box", props: p.mapValues { .value($0) })
    }

    @Test func boxFacesSitOnTheBoxAndFlipInside() {
        let out = Renderer.boxFaces(SIMD3(200, 100, 400), inside: false)
        #expect(out.map(\.name) == ["front", "back", "left", "right", "top", "bottom"])
        let back = out[1]
        #expect(back.center == SIMD3(0, 0, 200) && back.size == SIMD2(200, 100))
        #expect(out[2].size == SIMD2(400, 100) && out[4].center == SIMD3(0, -50, 0))
        let inside = Renderer.boxFaces(SIMD3(200, 100, 400), inside: true)
        #expect(inside[1].right == -back.right && inside[1].down == back.down)
    }

    @Test(.requiresMetal) func roomShowsItsBackWallAndCeilingFromInside() throws {
        // The default camera (z ≈ −275) is inside a 400×400×2000 room centred on z 500.
        let img = try render([box(["z": 500, "size": [400, 400, 2000], "inside": true])])
        let c = pixel(img, 100, 100)
        #expect(c.r > 200 && c.g < 30 && c.b < 30)  // back wall
        let up = pixel(img, 100, 2)
        #expect(up.b > 200 && up.r < 30)  // ceiling
    }

    @Test(.requiresMetal) func roomSeenFromOutsideDropsItsNearWalls() throws {
        let inside = try render([box(["z": 1000, "size": [300, 300, 300], "inside": true])])
        let c = pixel(inside, 100, 100)
        #expect(c.r > 200 && c.g < 30)  // the back wall, through the missing front
        let solid = try render([box(["z": 1000, "size": [300, 300, 300]])])
        let s = pixel(solid, 100, 100)
        #expect(s.g > 200 && s.r < 30)  // a closed box shows its front
    }

    /// A w×h PNG of one grey level (or colour) in a fresh assets folder.
    func png(_ name: String, in dir: URL, r: CGFloat, g: CGFloat, b: CGFloat, size: Int = 64) throws {
        let ctx = try #require(ImageData.context(size, size))
        ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let img = try #require(ctx.makeImage())
        let data = try #require(ImageData.png(img))
        try data.write(to: dir.appendingPathComponent(name))
    }

    @Test(.requiresMetal) func reliefBringsThePictureForward() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("relief-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try png("pic.png", in: dir, r: 0, g: 0, b: 1)
        try png("near.png", in: dir, r: 1, g: 1, b: 1)
        func scene(depth: Bool) -> Scene {
            var s = Scene(id: "s", duration: 1)
            s.background = .value("#000000")
            var img: [String: JSONValue] = [
                "src": "pic.png", "x": 100, "y": 100, "z": 600, "width": 300, "height": 300, "3d": true,
            ]
            if depth { img["depth"] = "near.png"; img["depthAmount"] = 400 }
            s.nodes = [
                Node(id: "img", type: "image", props: img.mapValues { .value($0) }),
                square("card", "#FF0000", z: 400, size: 120),
            ]
            return s
        }
        let p = Project(name: "t", size: [200, 200])
        let r = try Renderer()
        // Flat at z 600 the picture is behind the red card (z 400); pushed 400 px forward (z 200) it hides it.
        let flat = pixel(try r.image(scene: scene(depth: false), project: p, assets: dir, time: 0), 100, 100)
        #expect(flat.r > 200 && flat.b < 30)
        let relief = pixel(try r.image(scene: scene(depth: true), project: p, assets: dir, time: 0), 100, 100)
        #expect(relief.b > 200 && relief.r < 30)
    }

    // MARK: Light pools on box surfaces

    /// A size×size PNG of vertical stripes, 8 px dark (0.2 grey), 8 px light (0.6 grey).
    func stripes(_ name: String, in dir: URL, size: Int = 64) throws {
        let ctx = try #require(ImageData.context(size, size))
        for x in stride(from: 0, to: size, by: 8) {
            let v: CGFloat = (x / 8) % 2 == 0 ? 0.2 : 0.6
            ctx.setFillColor(CGColor(red: v, green: v, blue: v, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 8, height: size))
        }
        let img = try #require(ctx.makeImage())
        let data = try #require(ImageData.png(img))
        try data.write(to: dir.appendingPathComponent(name))
    }

    /// A striped box table top seen from above at an angle, optionally under a warm light pool lying on it.
    /// Returns the (min, max) luminance along the middle row of the table top.
    func tableTop(pool: [String: JSONValue]?, assets dir: URL) throws -> (lo: Double, hi: Double) {
        var s = Scene(id: "s", duration: 1)
        s.background = .value("#000000")
        s.camera = .value(["position": [100, -500, -150], "target": [100, 80, 300], "fov": 40])
        var nodes = [
            Node(
                id: "table", type: "box",
                props: ([
                    "x": 100, "y": 100, "z": 300, "size": [400, 40, 400], "shade": 0,
                    "top": ["src": "stripes.png", "tile": [4, 4]],
                ] as [String: JSONValue]).mapValues { .value($0) })
        ]
        if let pool {
            // The pool lies flat at the light's y: the table top (100 − 40 / 2).
            nodes.append(
                Node(
                    id: "spot", type: "light",
                    props: (["x": 100, "y": 80, "z": 300, "pool": .object(pool)] as [String: JSONValue])
                        .mapValues { .value($0) }))
        }
        s.nodes = nodes
        let img = try Renderer().image(scene: s, project: Project(name: "t", size: [200, 200]), assets: dir, time: 0)
        let lum = (80...120).map { x -> Double in
            let c = pixel(img, x, 100)
            return 0.2126 * Double(c.r) + 0.7152 * Double(c.g) + 0.0722 * Double(c.b)
        }
        return (lum.min()!, lum.max()!)
    }

    @Test(.requiresMetal) func lightPoolShowsOnABoxTable() throws {
        // The pool used to be drawn before the boxes and was painted over by the table top.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try stripes("stripes.png", in: dir)
        let dark = try tableTop(pool: nil, assets: dir)
        #expect(dark.hi > 60 && dark.lo > 5)  // the table top is in view
        for blend in ["add", "light"] {
            let lit = try tableTop(
                pool: ["radius": 200, "color": "#FFC890", "intensity": 2, "blend": .string(blend)], assets: dir)
            #expect(lit.hi > dark.hi * 1.3, "\(blend) pool should brighten the table top")
        }
    }

    @Test(.requiresMetal) func lightBlendPoolKeepsTheTextureContrast() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try stripes("stripes.png", in: dir)
        func contrast(_ v: (lo: Double, hi: Double)) -> Double { (v.hi - v.lo) / max(v.hi, 1) }
        let plain = contrast(try tableTop(pool: nil, assets: dir))
        let pool: [String: JSONValue] = ["radius": 200, "color": "#FFC890", "intensity": 1.2]
        var light = pool; light["blend"] = "light"
        // "light" multiplies the surface: the dark grain stays dark relative to the light grain.
        let kept = contrast(try tableTop(pool: light, assets: dir))
        #expect(kept > plain * 0.75)
        // "add" (a glow) lifts dark and light grain alike and flattens them.
        let washed = contrast(try tableTop(pool: pool, assets: dir))
        #expect(washed < kept * 0.8)
    }
}
