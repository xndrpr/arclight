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
}
