import AppKit
import Foundation
import Testing

@testable import ArclightCore

@Suite struct AssetWriterTests {
    func tempProject() throws -> ProjectStore {
        try TempProject("aw", name: "AW").store
    }

    @Test func svgBecomesPNGAsset() throws {
        let s = try tempProject()
        let svg =
            ##"<svg xmlns="http://www.w3.org/2000/svg" width="100" height="50" viewBox="0 0 100 50"><rect width="100" height="50" fill="#f00"/></svg>"##
        let w = try AssetWriter.writeSVG(svg, name: "badge", width: 400, to: s)
        #expect(w.src == "badge.png" && w.width == 400 && w.height == 200)
        let data = try Data(contentsOf: s.assetsURL.appendingPathComponent("badge.png"))
        #expect(NSBitmapImageRep(data: data)?.pixelsWide == 400)
    }

    @Test func base64ImageKeepsFormatAndRejectsGarbage() throws {
        let s = try tempProject()
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let w = try AssetWriter.writeImage(png, name: "../../evil", to: s)
        #expect(w.src == "evil.png" && w.width == 8 && w.height == 4)
        #expect(FileManager.default.fileExists(atPath: s.assetsURL.appendingPathComponent("evil.png").path))
        #expect(throws: AssetWriter.Failure.self) {
            try AssetWriter.writeImage(Data("not an image".utf8), name: "x.png", to: s)
        }
    }

    @Test func symbolSaveAddsAndReplacesInPack() throws {
        let s = try tempProject()
        let id = try AssetWriter.saveSymbol(
            pack: "Brand", id: "Logo", name: "Logo", path: "M0 -100 L50 0 L-50 0 Z", rim: nil,
            evenOdd: false, scope: .project, project: s.url)
        #expect(id == "brand/logo")
        #expect(Symbols.exists("brand/logo", project: s.url))
        try AssetWriter.saveSymbol(
            pack: "brand", id: "logo", name: "Logo 2", path: "M0 -10 L5 0 L-5 0 Z", rim: nil,
            evenOdd: false, scope: .project, project: s.url)
        #expect(Symbols.all(project: s.url).filter { $0.id == "brand/logo" }.map(\.name) == ["Logo 2"])
        #expect(throws: AssetWriter.Failure.self) {
            try AssetWriter.saveSymbol(
                pack: "basic", id: "x", name: nil, path: "M0 0 L1 1 Z", rim: nil, evenOdd: false, scope: .project,
                project: s.url)
        }
        #expect(throws: AssetWriter.Failure.self) {
            try AssetWriter.saveSymbol(
                pack: "brand", id: "bad", name: nil, path: "nonsense", rim: nil, evenOdd: false, scope: .project,
                project: s.url)
        }
    }
}
