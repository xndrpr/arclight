import CoreGraphics
import Foundation
import Testing
import simd

@testable import ArclightCore

/// Per-layer effects: blend, clip, mask, outline, drop shadow, glow, blur, adjust; image fit / crop.
@Suite(.serialized, .requiresMetal) struct LayerEffectsTests {
    private static let project: Project = {
        var p = Project(name: "fx", size: [200, 100])
        p.theme["bg"] = "#000000"
        return p
    }()

    private func scene(_ nodes: [Node], bg: String = "#000000") -> ArclightCore.Scene {
        var s = ArclightCore.Scene(id: "s", duration: 1, nodes: nodes)
        s.background = .value(.string(bg))
        return s
    }

    private func rect(
        _ id: String, x: Double, y: Double, w: Double, h: Double, fill: String, _ extra: [String: JSONValue] = [:]
    ) -> Node {
        var props: [String: Prop] = [
            "shape": .value("rect"), "x": .value(.number(x)), "y": .value(.number(y)), "width": .value(.number(w)),
            "height": .value(.number(h)), "fill": .value(.string(fill)),
        ]
        for (k, v) in extra { props[k] = try! Prop(json: v) }
        return Node(id: id, type: "shape", props: props)
    }

    /// sRGB 8-bit RGBA of a pixel (top-left origin).
    private func px(_ img: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let ctx = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height))
        let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (Int(d[0]), Int(d[1]), Int(d[2]), Int(d[3]))
    }

    private func render(_ s: ArclightCore.Scene, assets: URL? = nil) throws -> CGImage {
        try Renderer().image(scene: s, project: Self.project, assets: assets, time: 0)
    }

    @Test func plainLayersSkipTheEffectsPath() throws {
        let plain = rect("r", x: 100, y: 50, w: 60, h: 40, fill: "#FF0000")
        let ev = Evaluator()
        let n = try #require(ev.evaluate(scene([plain]), T: 0).first)
        #expect(!Renderer.needsEffects(n))
        // "normal" blend through the effects path (forced by an empty-radius blur) looks the same as the plain path.
        let a = try render(scene([plain]))
        let b = try render(
            scene([rect("r", x: 100, y: 50, w: 60, h: 40, fill: "#FF0000", ["adjust": ["contrast": 1]])]))
        for (x, y) in [(100, 50), (75, 35), (128, 68), (10, 10)] {
            let p = px(a, x, y), q = px(b, x, y)
            #expect(abs(p.r - q.r) <= 2 && abs(p.g - q.g) <= 2 && abs(p.b - q.b) <= 2, "\(x),\(y): \(p) vs \(q)")
        }
    }

    @Test func outlineShadowAndGlowDrawAroundTheLayer() throws {
        let img = try render(
            scene([
                rect(
                    "r", x: 100, y: 50, w: 40, h: 20, fill: "#FF0000",
                    ["effects": ["outline": ["color": "#FFFFFF", "width": 6]]])
            ]))
        #expect(px(img, 100, 50).r > 240 && px(img, 100, 50).g < 20)  // the layer itself
        let edge = px(img, 100, 37)  // 3 px above the top edge (y 40): inside the 6 px outline
        #expect(edge.r > 230 && edge.g > 230 && edge.b > 230, "\(edge)")
        #expect(px(img, 100, 30).r < 10)  // 10 px out: past the outline

        let sh = try render(
            scene(
                [
                    rect(
                        "r", x: 100, y: 40, w: 40, h: 20, fill: "#FFFFFF",
                        ["effects": ["dropShadow": ["color": "#FF0000", "x": 0, "y": 20, "blur": 0, "opacity": 1]]])
                ],
                bg: "#000000"))
        #expect(px(sh, 100, 66).r > 200 && px(sh, 100, 66).g < 30)  // shadow 20 px below, red

        let gl = try render(
            scene([
                rect(
                    "r", x: 100, y: 50, w: 20, h: 20, fill: "#000000",
                    ["effects": ["glow": ["color": "#00FF00", "radius": 20, "intensity": 2]]])
            ]))
        #expect(px(gl, 100, 36).g > 40)  // light spills past the edge (y 40)
        #expect(px(gl, 5, 5).g < 5)
    }

    @Test func blurSoftensTheEdge() throws {
        let sharp = try render(scene([rect("r", x: 100, y: 50, w: 40, h: 40, fill: "#FFFFFF")]))
        let soft = try render(
            scene([rect("r", x: 100, y: 50, w: 40, h: 40, fill: "#FFFFFF", ["effects": ["blur": 8]])]))
        #expect(px(sharp, 100, 27).r < 10)  // 3 px outside the top edge (y 30)
        #expect(px(soft, 100, 27).r > 20)
        #expect(px(soft, 100, 50).r > 200)
    }

    @Test func clipAndMaskLimitWhereALayerShows() throws {
        let base = rect("base", x: 50, y: 50, w: 40, h: 40, fill: "#0000FF")
        let over = rect("over", x: 100, y: 50, w: 160, h: 20, fill: "#FF0000", ["clip": true])
        let img = try render(scene([base, over]))
        #expect(px(img, 50, 50).r > 200)  // inside the base: red over blue
        #expect(px(img, 150, 50).r < 10)  // outside the base: clipped away
        #expect(px(img, 50, 35).b > 200)  // base where the clip layer isn't

        let shape = rect("m", x: 150, y: 50, w: 20, h: 20, fill: "#FFFFFF")
        let masked = rect("img", x: 100, y: 50, w: 200, h: 100, fill: "#00FF00", ["mask": ["node": "m"]])
        let mi = try render(scene([shape, masked]))
        #expect(px(mi, 150, 50).g > 200 && px(mi, 150, 50).r < 10)  // shown inside the mask (mask itself not drawn)
        #expect(px(mi, 50, 50).g < 10)
        let inv = try render(
            scene([
                shape,
                rect("img", x: 100, y: 50, w: 200, h: 100, fill: "#00FF00", ["mask": ["node": "m", "invert": true]]),
            ]))
        #expect(px(inv, 150, 50).g < 10 && px(inv, 50, 50).g > 200)
    }

    @Test func blendModesMixWithTheBackground() throws {
        let mult = try render(
            scene([rect("r", x: 100, y: 50, w: 200, h: 100, fill: "#808080", ["blend": "multiply"])], bg: "#FF8000"))
        let p = px(mult, 100, 50)
        #expect(p.r > 120 && p.r < 220 && p.b < 10, "\(p)")  // orange darkened, still orange
        let scr = try render(
            scene([rect("r", x: 100, y: 50, w: 200, h: 100, fill: "#0000FF", ["blend": "screen"])], bg: "#FF0000"))
        let q = px(scr, 100, 50)
        #expect(q.r > 240 && q.b > 240, "\(q)")  // red + blue
    }

    @Test func adjustDesaturates() throws {
        let img = try render(
            scene([rect("r", x: 100, y: 50, w: 200, h: 100, fill: "#FF0000", ["adjust": ["saturation": 0]])]))
        let p = px(img, 100, 50)
        #expect(abs(p.r - p.g) < 6 && abs(p.g - p.b) < 6 && p.r > 20, "\(p)")
    }

    @Test func imageFitAndCropGeometry() throws {
        func node(_ props: [String: JSONValue]) -> EvalNode {
            EvalNode(
                node: Node(id: "i", type: "image"), world: matrix_identity_float4x4, opacity: 1, t: 0, props: props)
        }
        // A 200×100 picture in a 100×100 box: cover crops the sides, contain letterboxes.
        let cover = Renderer.imageQuad(
            node(["width": 100, "height": 100, "fit": "cover"]), box: CGSize(width: 100, height: 100),
            texture: (200, 100))
        #expect(cover.rect.z == 200 && cover.rect.w == 100 && cover.rect.x == -100)
        #expect(cover.clip == SIMD4(-50, -50, 50, 50))
        let contain = Renderer.imageQuad(
            node(["width": 100, "height": 100, "fit": "contain"]), box: CGSize(width: 100, height: 100),
            texture: (200, 100))
        #expect(contain.rect == SIMD4(-50, -25, 100, 50))
        let crop = Renderer.imageQuad(
            node(["width": 100, "crop": [0.5, 0, 0.5, 1]]), box: CGSize(width: 100, height: 50), texture: (200, 100))
        // The right half (100×100 px of picture) at width 100 → 100×100, drawn from a 200-wide quad shifted left.
        #expect(crop.rect == SIMD4(-150, -50, 200, 100))
        #expect(crop.clip == SIMD4(-50, -50, 50, 50))
    }

    @Test func schemaAcceptsEffectsAndRejectsTypos() throws {
        let good = scene([
            rect(
                "r", x: 0, y: 0, w: 1, h: 1, fill: "#fff",
                [
                    "blend": "multiply", "clip": true,
                    "effects": ["outline": ["width": 4, "color": "$fg"], "blur": 2],
                    "adjust": ["saturation": 0.5],
                ])
        ])
        #expect(Validator.validate(good).isEmpty, "\(Validator.validate(good))")
        let bad = scene([rect("r", x: 0, y: 0, w: 1, h: 1, fill: "#fff", ["blend": "darken-ish"])])
        #expect(!Validator.validate(bad).isEmpty)
        let typo = scene([rect("r", x: 0, y: 0, w: 1, h: 1, fill: "#fff", ["effects": ["outlne": ["width": 4]]])])
        #expect(!Validator.validate(typo).isEmpty)
    }
}
