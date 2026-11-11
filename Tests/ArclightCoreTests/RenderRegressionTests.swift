import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Metal
import Testing

@testable import ArclightCore

// Regression tests for the rendering and text bugs found in the 0.1.0 release work (B1–B3, B14, E1, E5, E6), plus
// the E2 and E7 checks that showed those two were not bugs.

/// One pixel of a rendered frame (the readback is BGRA, premultiplied).
private struct Px {
    var r: Int, g: Int, b: Int, a: Int
}

private func pixel(_ img: CGImage, _ x: Int, _ y: Int) -> Px {
    let d = CFDataGetBytePtr(img.dataProvider!.data!)!
    let i = y * img.bytesPerRow + x * 4
    return Px(r: Int(d[i + 2]), g: Int(d[i + 1]), b: Int(d[i]), a: Int(d[i + 3]))
}

private func scene(_ json: String) throws -> ArclightCore.Scene {
    try JSONDecoder().decode(ArclightCore.Scene.self, from: Data(json.utf8))
}

@Suite(.requiresMetal) struct RenderRegressionTests {
    // MARK: B1, B2, B3

    /// B1: the glyph cache must give each font size its own raster scale (raster / own size).
    @Test func b1_glyphCacheIsKeyedByFontSize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let cache = GlyphCache(device: device)
        let small = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let big = CTFontCreateWithName("Helvetica" as CFString, 25, nil)
        var ch: UniChar = 0x48  // "H"
        var glyph: CGGlyph = 0
        #expect(CTFontGetGlyphsForCharacters(big, &ch, &glyph, 1))
        // 24 pt at 1.05 and 25 pt at 1.0 both rasterize at 25 px.
        let first = try #require(cache.get(font: small, glyph: glyph, pixelScale: 1.05))
        #expect(abs(first.scale - 25.0 / 24.0) < 1e-9)
        let second = try #require(cache.get(font: big, glyph: glyph, pixelScale: 1))
        #expect(abs(second.scale - 1.0) < 1e-9)
    }

    /// B2: the symbol raster cache must return the rect for the requested size and zoom, not the first one cached.
    @Test func b2_symbolRasterCacheIsKeyedBySize() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        // size 105 at scale 1 and size 100 at scale 1.05 both rasterize 105 px tall, but cover different layer units.
        let a = (size: 105.0, scale: Float(1))
        let b = (size: 100.0, scale: Float(1.05))
        let fresh = SymbolRasterCache(device: device)
        let want = try #require(fresh.get("chess/knight", project: nil, size: b.size, pixelScale: b.scale))
        let shared = SymbolRasterCache(device: device)
        let first = try #require(shared.get("chess/knight", project: nil, size: a.size, pixelScale: a.scale))
        let got = try #require(shared.get("chess/knight", project: nil, size: b.size, pixelScale: b.scale))
        #expect(first.texture.height == want.texture.height)  // same raster height, so the keys collide
        #expect(first.rect != want.rect)  // and the correct rects differ
        #expect(got.rect == want.rect)
    }

    // MARK: B3, B14

    private static let wideMark = "M0 0 L40 0 L40 10 L0 10 Z"  // 4:1
    private static let tallMark = "M0 0 L10 0 L10 40 L0 40 Z"  // 1:4

    private func saveMark(_ path: String, in project: TempProject) throws {
        try AssetWriter.saveSymbol(
            pack: "brand", id: "mark", name: nil, path: path, rim: nil, evenOdd: false, scope: .project,
            project: project.url)
    }

    private func repeaterScene() throws -> ArclightCore.Scene {
        try scene(
            """
            {"id":"s","duration":1,"background":"#000000","nodes":[
              {"id":"r","type":"repeater","layout":"points","points":[[0,0,0]],"z":1500,
               "items":[{"symbol":"brand/mark","height":200}]}]}
            """)
    }

    /// B3: a symbol rewritten on disk (symbol_save) must show up in the sprite cache (the old sprite used to stay).
    @Test func b3_symbolSpriteUpdatesAfterRewrite() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let p = try TempProject("b3-sprite")
        defer { p.remove() }
        try saveMark(Self.wideMark, in: p)
        let cache = SymbolRasterCache(device: device)
        let before = try #require(cache.sprite("brand/mark", project: p.url))
        #expect(abs(before.bounds.width - 4) < 1e-6)
        try saveMark(Self.tallMark, in: p)
        let onDisk = try #require(Symbols.sprite("brand/mark", project: p.url))
        #expect(abs(onDisk.bounds.width - 0.25) < 1e-6)  // the pack loader itself sees the new art
        let after = try #require(cache.sprite("brand/mark", project: p.url))
        #expect(abs(after.bounds.width - 0.25) < 1e-6)
    }

    /// B3: the repeater sprite atlas must be rebuilt after a symbol is rewritten; its key has only the item JSON.
    @Test func b3_atlasUpdatesAfterSymbolRewrite() throws {
        let p = try TempProject("b3-atlas")
        defer { p.remove() }
        try saveMark(Self.wideMark, in: p)
        let r = try Renderer()
        let proj = Project(name: "t", size: [160, 90])
        let sc = try repeaterScene()
        _ = try r.image(scene: sc, project: proj, assets: p.store.assetsURL, time: 0)
        let first = try #require(r.atlases.values.first)
        #expect(abs(first.cells[0].aspect - 4) < 0.01)
        try saveMark(Self.tallMark, in: p)
        _ = try r.image(scene: sc, project: proj, assets: p.store.assetsURL, time: 0)
        #expect(r.atlases.values.contains { abs($0.cells[0].aspect - 0.25) < 0.01 })
    }

    /// B3: the same symbol id in another project must not reuse the atlas built for the first project.
    @Test func b3_atlasIsNotSharedAcrossProjects() throws {
        let p1 = try TempProject("b3-p1"), p2 = try TempProject("b3-p2")
        defer { p1.remove(); p2.remove() }
        try saveMark(Self.wideMark, in: p1)
        try saveMark(Self.tallMark, in: p2)
        let r = try Renderer()
        let proj = Project(name: "t", size: [160, 90])
        let sc = try repeaterScene()
        _ = try r.image(scene: sc, project: proj, assets: p1.store.assetsURL, time: 0)
        _ = try r.image(scene: sc, project: proj, assets: p2.store.assetsURL, time: 0)
        #expect(r.atlases.values.contains { abs($0.cells[0].aspect - 0.25) < 0.01 })
    }

    /// B3: an image item rewritten under the same name (asset_write) must rebuild the atlas.
    @Test func b3_atlasUpdatesAfterImageRewrite() throws {
        let p = try TempProject("b3-image")
        defer { p.remove() }
        func writePNG(width: Int, height: Int) throws {
            let ctx = try #require(
                CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            try FileManager.default.createDirectory(at: p.store.assetsURL, withIntermediateDirectories: true)
            try ImageFile.writePNG(ctx.makeImage()!, to: p.store.assetsURL.appendingPathComponent("mark.png"))
        }
        let r = try Renderer()
        let proj = Project(name: "t", size: [160, 90])
        let sc = try scene(
            """
            {"id":"s","duration":1,"background":"#000000","nodes":[
              {"id":"r","type":"repeater","layout":"points","points":[[0,0,0]],"z":1500,
               "items":[{"src":"mark.png","height":200}]}]}
            """)
        try writePNG(width: 40, height: 10)
        _ = try r.image(scene: sc, project: proj, assets: p.store.assetsURL, time: 0)
        #expect(r.atlases.values.contains { abs($0.cells[0].aspect - 4) < 0.01 })
        try writePNG(width: 10, height: 40)
        _ = try r.image(scene: sc, project: proj, assets: p.store.assetsURL, time: 0)
        #expect(r.atlases.values.contains { abs($0.cells[0].aspect - 0.25) < 0.01 })
    }

    /// B14: movie export must render with draft and solo off, whatever the editor viewport left on the renderer.
    @Test func b14_exportIgnoresDraftAndSolo() throws {
        let r = try Renderer()
        let proj = Project(name: "t", size: [320, 180])
        let sc = try scene(
            """
            {"id":"s","duration":0.1,"background":"#000000","post":{"motionBlur":3},"nodes":[
              {"id":"a","type":"shape","shape":"rect","width":50,"height":50,"x":100,"y":90}]}
            """)
        r.draft = true
        r.only = ["a"]
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-b14-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        var seen: [(draft: Bool, only: Set<String>?)] = []
        let res = try Exporter(renderer: r).export(
            scene: sc, project: proj, assets: nil, to: out, options: ExportOptions(),
            progress: { _, _ in seen.append((r.draft, r.only)) })
        #expect(res.frames > 0 && seen.count == res.frames)
        #expect(seen.allSatisfy { !$0.draft })
        #expect(seen.allSatisfy { $0.only == nil })
        // The viewport's settings are back afterwards.
        #expect(r.draft && r.only == ["a"])
    }

    /// B14: stills and PNG sequences also draw every layer, even when the viewport solos another one.
    @Test func b14_stillAndPNGSequenceIgnoreSolo() throws {
        let r = try Renderer()
        let proj = Project(name: "t", size: [200, 100])
        let sc = try scene(
            """
            {"id":"s","duration":0.05,"background":"#000000","nodes":[
              {"id":"a","type":"shape","shape":"rect","width":50,"height":50,"x":100,"y":50,"fill":"#FFFFFF"}]}
            """)
        r.only = ["other"]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-b14-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ex = Exporter(renderer: r)
        func centre(_ url: URL) throws -> Int {
            let src = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
            let img = try #require(CGImageSourceCreateImageAtIndex(src, 0, nil))
            let ctx = try #require(
                CGContext(
                    data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            let d = ctx.data!.assumingMemoryBound(to: UInt8.self)
            return Int(d[(img.height / 2 * img.width + img.width / 2) * 4 + 1])
        }
        let still = try ex.exportStill(
            scene: sc, project: proj, assets: nil, time: 0, to: dir.appendingPathComponent("still.png"))
        #expect(try centre(still) > 250)
        var o = ExportOptions()
        o.format = .png
        let seq = try ex.export(
            scene: sc, project: proj, assets: nil, to: dir.appendingPathComponent("seq.png"), options: o)
        #expect(try centre(seq.url.appendingPathComponent("s_00000.png")) > 250)
        #expect(r.only == ["other"])
    }

    // MARK: E1, E2, E7

    private func render(
        _ r: Renderer, _ json: String, theme: [String: JSONValue]? = nil, size: [Int] = [200, 100],
        time: Double = 0
    ) throws -> CGImage {
        var proj = Project(name: "t", size: size)
        if let theme { proj.theme = theme }
        return try r.image(scene: try scene(json), project: proj, assets: nil, time: time)
    }

    private func whiteRect(post: String, threeD: Bool = false) -> String {
        """
        {"id":"s","duration":2,"background":"#000000","post":\(post),"nodes":[
          {"id":"w","type":"shape","shape":"rect","width":40,"height":40,"x":100,"y":50,"fill":"#FFFFFF",
           "3d":\(threeD)}]}
        """
    }

    /// E1: bloom must pick up 2D layers; a white rect on black glows into the pixels around it.
    @Test func e1_bloomIncludes2DLayers() throws {
        let r = try Renderer()
        let bloom = #"{"bloom":{"intensity":1,"threshold":0.5}}"#
        let off = try render(r, whiteRect(post: "{}"))
        let on = try render(r, whiteRect(post: bloom))
        #expect(pixel(off, 100, 50).g > 250)  // the rect itself is white
        #expect(pixel(off, 126, 50).g == 0)
        // Control: the same rect on the 3D layer (the examples' workaround) does glow at the probed pixel.
        let world = try render(r, whiteRect(post: bloom, threeD: true))
        #expect(pixel(world, 126, 50).g > 5)
        let outside = pixel(on, 126, 50).g
        #expect(outside > pixel(off, 126, 50).g + 5)
    }

    /// E1: the glow lies over 2D layers too, so a full-frame 2D background doesn't hide it (graded or not).
    @Test func e1_bloomShowsOverA2DBackground() throws {
        let r = try Renderer()
        for gradeOverlay in [false, true] {
            func frame(_ bloom: Bool) throws -> CGImage {
                let post = bloom ? #""bloom":{"intensity":1,"threshold":0.5},"# : ""
                return try render(
                    r,
                    """
                    {"id":"s","duration":2,"background":"#000000","post":{\(post)"gradeOverlay":\(gradeOverlay)},"nodes":[
                      {"id":"bg","type":"shape","shape":"rect","width":200,"height":100,"x":100,"y":50,"fill":"#101010"},
                      {"id":"w","type":"shape","shape":"rect","width":40,"height":40,"x":100,"y":50,"fill":"#FFFFFF"}]}
                    """)
            }
            let off = try frame(false), on = try frame(true)
            #expect(pixel(on, 126, 50).g > pixel(off, 126, 50).g + 5)
        }
    }

    private static let inkTheme: [String: JSONValue] = [
        "bg": "#000000", "fg": "#F2EFE6", "ink": "#FF0000", "display": "Helvetica-Bold", "body": "Helvetica",
    ]

    /// E2a: `post.fade.color` given as a theme token must fade to that token's colour.
    @Test func e2a_fadeColorToken() throws {
        let r = try Renderer()
        let sc = """
            {"id":"s","duration":2,"background":"#000000","post":{"fade":{"in":1,"color":"$ink"}},"nodes":[]}
            """
        let img = try render(r, sc, theme: Self.inkTheme, time: 0)  // fade-in at t = 0: fully faded
        let p = pixel(img, 100, 50)
        #expect(p.r > 250 && p.g < 5 && p.b < 5)
    }

    /// E2b: at full fade the frame is exactly the fade colour, whatever vignette, tonemap or exposure the grade has.
    @Test func e2b_fullFadeIsFadeColourUnderGrade() throws {
        let r = try Renderer()
        let sc = """
            {"id":"s","duration":2,"background":"#808080","post":{"vignette":{"amount":0.9,"softness":0.5},"tonemap":true,
              "exposure":1,"fade":{"in":1,"color":"#204060"}},"nodes":[]}
            """
        let img = try render(r, sc, time: 0)
        for (x, y) in [(0, 0), (100, 50), (199, 99)] {
            let p = pixel(img, x, y)
            #expect(abs(p.r - 0x20) <= 2 && abs(p.g - 0x40) <= 2 && abs(p.b - 0x60) <= 2)
        }
    }

    /// E7: not reproducible. With or without gradeOverlay, a rect and a text layer of one colour dim alike at mid-fade.
    @Test func e7_endFadeDimsShapesAndTextAlike() throws {
        let r = try Renderer()
        let looks = [
            (bg: "#000000", ink: "#FFFFFF", extra: ""),
            (bg: "#203040", ink: "#FF8800", extra: ""),
            (bg: "#203040", ink: "#FF8800", extra: #","tonemap":true,"vignette":0.5"#),
            (bg: "#000000", ink: "#C8C8C8", extra: #","exposure":-0.5"#),
        ]
        for overlay in [true, false] {
            for look in looks {
                let sc = """
                    {"id":"s","duration":2,"background":"\(look.bg)","post":{"gradeOverlay":\(overlay),"fade":{"out":1,"color":"#000000"}\(look.extra)},"nodes":[
                      {"id":"w","type":"shape","shape":"rect","width":60,"height":60,"x":50,"y":50,"fill":"\(look.ink)"},
                      {"id":"t","type":"text","text":"I","font":"Helvetica-Bold","size":100,"x":140,"y":0,"color":"\(look.ink)"}]}
                    """
                let img = try render(r, sc, time: 1.5)
                var text = Px(r: 0, g: 0, b: 0, a: 0)  // the brightest (fully covered) text pixel
                for y in 0..<100 {
                    for x in 120..<170 where pixel(img, x, y).g + pixel(img, x, y).r > text.g + text.r {
                        text = pixel(img, x, y)
                    }
                }
                let rect = pixel(img, 50, 50)
                #expect(abs(rect.r - text.r) <= 2 && abs(rect.g - text.g) <= 2 && abs(rect.b - text.b) <= 2)
            }
        }
    }

    // MARK: E5, E6

    /// Horizontal ink extent of a layout, in node space (left edge of the leftmost glyph, right edge of the rightmost).
    private func inkSpan(_ l: TextLayout) -> (left: CGFloat, right: CGFloat) {
        var left = CGFloat.infinity, right = -CGFloat.infinity
        for g in l.glyphs {
            var glyph = g.glyph
            let b = CTFontGetBoundingRectsForGlyphs(g.font, .default, &glyph, nil, 1)
            left = min(left, g.x + b.minX)
            right = max(right, g.x + b.maxX)
        }
        return (left, right)
    }

    /// E5: centre-aligned text must have its ink centred on x, trailing tracking excluded.
    @Test func e5_centreAlignExcludesTrailingTracking() {
        func layout(_ tracking: CGFloat) -> TextLayout {
            TextLayout(
                text: "HH", fontName: "Helvetica-Bold", size: 100, tracking: tracking, lineHeight: 1.1, align: "center")
        }
        let plain = inkSpan(layout(0))
        #expect(abs(plain.left + plain.right) < 1)  // control: symmetric "H" bearings, centred without tracking
        let t = inkSpan(layout(40))
        #expect(abs(t.left + t.right) < 1)
    }

    /// E5: right-aligned text ends at x, and the layout width (selection bounds) excludes the trailing tracking.
    @Test func e5_rightAlignAndWidthExcludeTrailingTracking() {
        func layout(_ tracking: CGFloat, _ align: String) -> TextLayout {
            TextLayout(
                text: "HH", fontName: "Helvetica-Bold", size: 100, tracking: tracking, lineHeight: 1.1, align: align)
        }
        let plain = inkSpan(layout(0, "right")), tracked = inkSpan(layout(40, "right"))
        #expect(abs(plain.right - tracked.right) < 1e-6)
        #expect(abs(layout(40, "left").width - layout(0, "left").width - 40) < 1e-6)  // one gap of tracking, not two
    }

    /// E6: two glyphs that exactly touch must not show a lighter column at the joint.
    @Test func e6_noHairlineWhereGlyphsTouch() throws {
        let r = try Renderer()
        let font = "Helvetica-Bold", size: CGFloat = 100
        func layout(_ tracking: CGFloat) -> TextLayout {
            TextLayout(text: "II", fontName: font, size: size, tracking: tracking, lineHeight: 1.1, align: "left")
        }
        func ink(_ g: TextLayout.Glyph) -> CGRect {
            var glyph = g.glyph
            return CTFontGetBoundingRectsForGlyphs(g.font, .default, &glyph, nil, 1).offsetBy(dx: g.x, dy: 0)
        }
        // Tracking that closes the gap between the two stems exactly, and an origin that puts the joint at x.5.
        let gap = ink(layout(0).glyphs[1]).minX - ink(layout(0).glyphs[0]).maxX
        let tracking = -gap
        let l = layout(tracking)
        let joint = ink(l.glyphs[1]).minX
        #expect(abs(ink(l.glyphs[0]).maxX - joint) < 1e-6)
        let originX = 60.5 - joint
        for reveal in [false, true] {
            let rv = reveal ? #","reveal":{"by":"char","stagger":0,"duration":0.001,"delay":0}"# : ""
            let sc = """
                {"id":"s","duration":1,"background":"#000000","nodes":[
                  {"id":"t","type":"text","text":"II","font":"\(font)","size":\(Int(size)),"tracking":\(tracking),
                   "x":\(originX),"y":0,"color":"#FFFFFF"\(rv)}]}
                """
            let img = try render(r, sc, size: [200, 120], time: 0.5)
            let row = (0..<200).map { pixel(img, $0, 60).g }
            let inside = row.indices.filter { row[$0] > 0 }
            #expect(row[(inside.first! + 2)...(inside.last! - 2)].min()! >= 250)
        }
    }

    /// E6: a half-transparent text layer whose glyphs overlap is as light where they overlap as elsewhere (the layer
    /// is one shape).
    @Test func e6_overlappingGlyphsAtHalfOpacity() throws {
        let r = try Renderer()
        func frame(_ tracking: Int, opacity: Double) throws -> [Int] {
            let img = try render(
                r,
                """
                {"id":"s","duration":1,"background":"#000000","nodes":[
                  {"id":"t","type":"text","text":"II","font":"Helvetica-Bold","size":100,"tracking":\(tracking),
                   "x":40,"y":0,"color":"#FFFFFF","opacity":\(opacity)}]}
                """, size: [200, 120])
            return (0..<200).map { pixel(img, $0, 60).g }
        }
        let row = try frame(-20, opacity: 0.5)
        let lit = row.filter { $0 > 0 }.dropFirst(2).dropLast(2)
        #expect(lit.count > 18)  // two stems, partly overlapping
        #expect(lit.max()! - lit.min()! <= 2)  // no lighter band where the stems overlap
    }

}
