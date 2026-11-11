import CoreText
import Foundation
import Metal

/// Glyph positions for a text node, with char/word/line unit indices for kinetic animators.
/// Node space: x from the alignment point, y = 0 at the cap-height top of the first line, y down.
struct TextLayout {
    struct Glyph {
        let font: CTFont
        let glyph: CGGlyph
        let x: CGFloat
        let baseline: CGFloat
        let advance: CGFloat
        let char: Int
        let word: Int
        let line: Int
    }
    struct Line { let top: CGFloat; let bottom: CGFloat }

    var glyphs: [Glyph] = []
    var lines: [Line] = []
    var unitCount: [String: Int] = [:]
    var unitCenter: [String: [Int: CGPoint]] = [:]
    var width: CGFloat = 0
    var height: CGFloat = 0
    /// Smallest horizontal gap between the ink boxes of neighbouring glyphs on a line (negative when they overlap,
    /// infinity with fewer than two glyphs). See `Renderer.glyphsTouch`.
    var minInkGap: CGFloat = .infinity

    static func fontExists(_ name: String) -> Bool {
        let f = CTFontCreateWithName(name as CFString, 12, nil)
        let ps = CTFontCopyPostScriptName(f) as String
        let fam = CTFontCopyFamilyName(f) as String
        return ps == name || fam == name
    }

    init(
        text: String, fontName: String, size: CGFloat, tracking: CGFloat, lineHeight: CGFloat, align: String,
        tabular: Bool = false
    ) {
        var base = CTFontCreateWithName(fontName as CFString, size, nil)
        if tabular {
            // Monospaced digits so counters don't jitter (OpenType tnum / AAT number spacing).
            let feature: [CFString: Any] = [kCTFontFeatureTypeIdentifierKey: 6, kCTFontFeatureSelectorIdentifierKey: 0]
            let desc = CTFontDescriptorCreateWithAttributes(
                [kCTFontFeatureSettingsAttribute: [feature]] as CFDictionary)
            base = CTFontCreateCopyWithAttributes(base, size, nil, desc)
        }
        let cap = CTFontGetCapHeight(base), asc = CTFontGetAscent(base), desc = CTFontGetDescent(base)
        var charIdx = 0, wordIdx = -1
        var bounds: [String: [Int: (CGFloat, CGFloat, CGFloat)]] = ["char": [:], "word": [:], "line": [:]]

        for (li, lineText) in text.components(separatedBy: "\n").enumerated() {
            let baseline = cap + CGFloat(li) * size * lineHeight
            lines.append(Line(top: baseline - asc, bottom: baseline + desc))
            let attr = NSAttributedString(
                string: lineText,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): base,
                    NSAttributedString.Key(kCTKernAttributeName as String): tracking,
                ])
            let ctLine = CTLineCreateWithAttributedString(attr)
            // The kern attribute also adds the tracking after the last character; it isn't part of the line.
            var w = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            if !lineText.isEmpty { w -= tracking }
            width = max(width, w)
            let offset: CGFloat = align == "center" ? -w / 2 : align == "right" ? -w : 0

            // UTF-16 offset → word index (words separated by whitespace, counted across lines).
            let units = Array(lineText.utf16)
            var wordOf = [Int](repeating: 0, count: units.count + 1)
            var inWord = false
            for (k, u) in units.enumerated() {
                let space = u == 32 || u == 9 || u == 0xA0
                if !space && !inWord { wordIdx += 1 }
                inWord = !space
                wordOf[k] = wordIdx
            }

            for run in CTLineGetGlyphRuns(ctLine) as! [CTRun] {
                let n = CTRunGetGlyphCount(run)
                guard n > 0 else { continue }
                let attrs = CTRunGetAttributes(run) as NSDictionary
                let font = attrs[kCTFontAttributeName as String] as! CTFont
                var gl = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
                var adv = [CGSize](repeating: .zero, count: n), idx = [CFIndex](repeating: 0, count: n)
                CTRunGetGlyphs(run, CFRange(location: 0, length: n), &gl)
                CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
                CTRunGetAdvances(run, CFRange(location: 0, length: n), &adv)
                CTRunGetStringIndices(run, CFRange(location: 0, length: n), &idx)
                for k in 0..<n {
                    let si = idx[k]
                    let u = si < units.count ? units[si] : 32
                    if u == 32 || u == 9 || u == 0xA0 { continue }
                    let g = Glyph(
                        font: font, glyph: gl[k], x: offset + pos[k].x, baseline: baseline,
                        advance: adv[k].width, char: charIdx, word: wordOf[min(si, units.count)], line: li)
                    glyphs.append(g)
                    for (mode, unit) in [("char", g.char), ("word", g.word), ("line", g.line)] {
                        let b = bounds[mode]![unit] ?? (g.x, g.x + g.advance, baseline)
                        bounds[mode]![unit] = (min(b.0, g.x), max(b.1, g.x + g.advance), baseline)
                    }
                    charIdx += 1
                }
            }
        }
        // Renumber word units densely so stagger has no gaps.
        let wordIds = Array(Set(glyphs.map(\.word))).sorted()
        let remap = Dictionary(uniqueKeysWithValues: wordIds.enumerated().map { ($1, $0) })
        glyphs = glyphs.map {
            Glyph(
                font: $0.font, glyph: $0.glyph, x: $0.x, baseline: $0.baseline, advance: $0.advance,
                char: $0.char, word: remap[$0.word]!, line: $0.line)
        }
        var wb: [Int: (CGFloat, CGFloat, CGFloat)] = [:]
        for (old, b) in bounds["word"]! { if let n = remap[old] { wb[n] = b } }
        bounds["word"] = wb

        for (mode, dict) in bounds {
            unitCount[mode] = dict.count
            unitCenter[mode] = dict.mapValues { CGPoint(x: ($0.0 + $0.1) / 2, y: $0.2 - cap / 2) }
        }
        height = (lines.last?.bottom ?? 0) - (lines.first?.top ?? 0)

        var prev: (line: Int, maxX: CGFloat)?
        for g in glyphs {
            var glyph = g.glyph
            let ink = CTFontGetBoundingRectsForGlyphs(g.font, .default, &glyph, nil, 1)
            guard ink.width > 0 else { continue }
            var maxX = g.x + ink.maxX
            if let p = prev, p.line == g.line {
                minInkGap = min(minInkGap, g.x + ink.minX - p.maxX)
                maxX = max(maxX, p.maxX)
            }
            prev = (g.line, maxX)
        }
    }

    func unit(_ g: Glyph, _ mode: String) -> Int { mode == "word" ? g.word : mode == "line" ? g.line : g.char }
}

/// Rasterized glyph coverage textures, cached per font, point size, quantized pixel size and glyph.
final class GlyphCache {
    struct Entry {
        let texture: MTLTexture
        /// Bitmap origin relative to the pen position, in raster pixels (y up from baseline).
        let ox: CGFloat, oy: CGFloat
        let w: Int, h: Int
        /// Raster pixels per node unit.
        let scale: CGFloat
    }

    let device: MTLDevice
    private var cache: [String: Entry?] = [:]

    init(device: MTLDevice) { self.device = device }

    func get(font: CTFont, glyph: CGGlyph, pixelScale: CGFloat) -> Entry? {
        // Quantize to 5% steps so continuous zooms reuse rasters.
        let q = pow(1.05, (log(max(pixelScale, 0.05)) / log(1.05)).rounded())
        let size = CTFontGetSize(font)
        let raster = max(1, (size * q).rounded())
        // The point size is part of the key: two sizes can share a raster size but not the scale.
        let key = "\(CTFontCopyPostScriptName(font))|\(size)|\(raster)|\(glyph)"
        if let e = cache[key] { return e }
        let f = CTFontCreateCopyWithAttributes(font, raster, nil, nil)
        var g = glyph
        let r = CTFontGetBoundingRectsForGlyphs(f, .default, &g, nil, 1)
        guard r.width > 0, r.height > 0 else { cache[key] = .some(nil); return nil }
        let pad: CGFloat = 2
        let w = Int(ceil(r.width + pad * 2)), h = Int(ceil(r.height + pad * 2))
        guard let ctx = CoverageMask.context(width: w, height: h) else { return nil }
        ctx.setShouldSmoothFonts(false)
        let ox = floor(r.minX - pad), oy = floor(r.minY - pad)
        var p = CGPoint(x: -ox, y: -oy)
        CTFontDrawGlyphs(f, &g, &p, 1, ctx)

        guard let tex = CoverageMask.texture(ctx, device: device) else { return nil }
        let e = Entry(texture: tex, ox: ox, oy: oy, w: w, h: h, scale: raster / size)
        cache[key] = e
        return e
    }
}
