import AppKit
import Foundation
import Testing

@testable import ArclightCore

/// Edge cases of `ThemePresets` matching / naming and `AssetWriter` naming and limits.
@Suite(.serialized) struct LibraryCharacterizationTests {
    @Test func presetMatchingRules() {
        let p = ThemePreset(
            id: "x", name: "X", tokens: ["bg": "#000000", "fg": "#FFFFFF", "accent": "#FF0000", "display": "Futura"])
        // Needs bg and fg, at least three shared tokens, and every shared one equal (strings case-insensitively).
        #expect(ThemePresets.matches(p, ["bg": "#000000", "fg": "#ffffff", "accent": "#ff0000", "extra": 1]))
        #expect(!ThemePresets.matches(p, ["bg": "#000000", "fg": "#FFFFFF"]))
        #expect(!ThemePresets.matches(p, ["bg": "#000000", "fg": "#FFFFFF", "accent": "#00FF00"]))
        #expect(!ThemePresets.matches(p, ["fg": "#FFFFFF", "accent": "#FF0000", "display": "Futura"]))
        // Numbers compare through their string form, so "1" and 1 are the same token value.
        #expect(ThemePresets.same(1, 1) && ThemePresets.same("1", 1) && !ThemePresets.same(1, 2))
    }

    @Test func presetSlugsAndLookup() {
        #expect(ThemePresets.slug("  Brand — Dark!! v2 ") == "brand-dark-v2")
        #expect(ThemePresets.slug("Ünïcode Ok") == "ünïcode-ok")
        #expect(ThemePresets.slug("---") == "")
        let first = ThemePresets.builtIn[0]
        #expect(ThemePresets.get(first.name.uppercased())?.id == first.id)
        #expect(ThemePresets.get(" \(first.id) ")?.id == first.id)
        #expect(ThemePresets.get("no such preset") == nil)
        #expect(ThemePresets.describe("pool") == "Spotlight / light-pool colour" && ThemePresets.describe("zzz") == nil)
        #expect(ThemePresets.standardKeys.allSatisfy { ThemePresets.describe($0) != nil })
    }

    @Test func assetNamesAreCleaned() throws {
        #expect(try AssetWriter.cleanName("../a/b/My Logo!.png", defaultExt: "png") == "My Logo-.png")
        #expect(try AssetWriter.cleanName("...hidden", defaultExt: "jpg") == "hidden.jpg")
        #expect(try AssetWriter.cleanName("  badge  ", defaultExt: "png") == "badge.png")
        #expect(try AssetWriter.cleanName("emoji😀", defaultExt: "png") == "emoji-.png")
        #expect(throws: AssetWriter.Failure.self) { try AssetWriter.cleanName("...", defaultExt: "png") }
        #expect(try AssetWriter.cleanName("dir/", defaultExt: "png") == "dir.png")
    }

    func tempProject() throws -> ProjectStore {
        try TempProject("lib", name: "L").store
    }

    @Test func imageExtensionFollowsTheData() throws {
        let s = try tempProject()
        defer { try? FileManager.default.removeItem(at: s.url) }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let jpeg = rep.representation(using: .jpeg, properties: [:])!
        // A known image extension is kept even if it doesn't match the bytes; an unknown one is replaced.
        #expect(try AssetWriter.writeImage(jpeg, name: "photo.png", to: s).src == "photo.png")
        #expect(try AssetWriter.writeImage(jpeg, name: "photo.txt", to: s).src == "photo.jpeg")
        #expect(try AssetWriter.writeImage(jpeg, name: "noext", to: s).src == "noext.jpeg")
        // Too large is refused before decoding.
        #expect(throws: AssetWriter.Failure.self) {
            try AssetWriter.writeImage(Data(count: AssetWriter.maxBytes + 1), name: "big.png", to: s)
        }
    }

    @Test func svgSizeIsClampedAndValidated() throws {
        let s = try tempProject()
        defer { try? FileManager.default.removeItem(at: s.url) }
        let svg =
            ##"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="20"><rect width="10" height="20" fill="#0f0"/></svg>"##
        let tiny = try AssetWriter.writeSVG(svg, name: "t.jpg", width: 0, to: s)
        #expect(tiny.src == "t.png" && tiny.width == 1 && tiny.height == 2)
        let huge = try AssetWriter.writeSVG(svg, name: "h", width: 100_000, to: s)
        #expect(huge.width == 8192 && huge.height == 16384)
        #expect(throws: AssetWriter.Failure.self) { try AssetWriter.writeSVG("<rect/>", name: "x", width: 10, to: s) }
    }

    @Test func symbolIdsAreSlugged() throws {
        let s = try tempProject()
        defer { try? FileManager.default.removeItem(at: s.url) }
        let id = try AssetWriter.saveSymbol(
            pack: " My Pack ", id: "Big Star!", name: nil, path: "M0 -10 L5 0 L-5 0 Z", rim: "M-2 -5 L2 -5",
            evenOdd: true, scope: .project, project: s.url)
        #expect(id == "my-pack/big-star")
        let pack = try JSONDecoder().decode(
            JSONValue.self, from: Data(contentsOf: s.url.appendingPathComponent("symbols/my-pack.json")))
        let item = pack["symbols"]?.array?.first
        #expect(item?["name"] == "Big Star!" && item?["fillRule"] == "evenodd" && item?["rim"] == "M-2 -5 L2 -5")
        #expect(throws: AssetWriter.Failure.self) {
            try AssetWriter.saveSymbol(
                pack: "!!", id: "x", name: nil, path: "M0 0 L1 1 Z", rim: nil, evenOdd: false, scope: .project,
                project: s.url)
        }
        #expect(throws: AssetWriter.Failure.self) {
            try AssetWriter.saveSymbol(
                pack: "p", id: "x", name: nil, path: "M0 0 L1 1 Z", rim: nil, evenOdd: false, scope: .project,
                project: nil)
        }
    }
}
