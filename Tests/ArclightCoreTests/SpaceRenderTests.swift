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
}
