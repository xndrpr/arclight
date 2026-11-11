import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Writing assets and symbols from data (MCP `asset_write`, `symbol_save`): AI agents that can't create files on this
/// Mac (or don't want to) send the content itself.
public enum AssetWriter {
    public enum Failure: Error, CustomStringConvertible {
        case bad(String)
        public var description: String { if case .bad(let s) = self { return s }; return "invalid asset" }
    }

    /// Formats image layers can load (Metal's texture loader / ImageIO).
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "gif", "bmp"]
    static let maxBytes = 25 * 1024 * 1024

    public struct Written: Sendable { public let src: String; public let width: Int; public let height: Int }

    /// A safe file name inside assets/: no folders, no leading dot, known extension.
    static func cleanName(_ raw: String, defaultExt: String) throws -> String {
        var n = (raw as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        n = n.replacingOccurrences(of: "[^A-Za-z0-9._ -]", with: "-", options: .regularExpression)
        while n.hasPrefix(".") { n.removeFirst() }
        guard !n.isEmpty else { throw Failure.bad("name is empty") }
        if (n as NSString).pathExtension.isEmpty { n += "." + defaultExt }
        return n
    }

    /// Writes encoded image bytes (PNG, JPEG, HEIC…) into the project's assets/.
    public static func writeImage(_ data: Data, name: String, to store: ProjectStore) throws -> Written {
        guard data.count <= maxBytes else { throw Failure.bad("image is larger than \(maxBytes / 1024 / 1024) MB") }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
            let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            throw Failure.bad(
                "data is not a readable image (send PNG, JPEG, HEIC or TIFF as base64; for vector art use svg or symbol_save)"
            )
        }
        let type = (CGImageSourceGetType(src) as String?).flatMap { UTType($0) }
        let ext = type?.preferredFilenameExtension ?? "png"
        var n = try cleanName(name, defaultExt: ext)
        if !imageExtensions.contains((n as NSString).pathExtension.lowercased()) {
            n = (n as NSString).deletingPathExtension + "." + ext
        }
        try write(data, name: n, store: store)
        return Written(src: n, width: img.width, height: img.height)
    }

    /// Renders SVG markup to a PNG in assets/ (image layers can't load SVG directly). `width` in pixels; height keeps
    /// the SVG's aspect ratio.
    public static func writeSVG(_ svg: String, name: String, width: Int, to store: ProjectStore) throws -> Written {
        guard svg.contains("<svg") else { throw Failure.bad("svg must contain an <svg> element") }
        guard let img = NSImage(data: Data(svg.utf8)), img.size.width > 0, img.size.height > 0 else {
            throw Failure.bad(
                "could not render this SVG (check it's a complete <svg> document with width/height or viewBox)")
        }
        let w = max(1, min(width, 8192)), h = max(1, Int((Double(w) * img.size.height / img.size.width).rounded()))
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { throw Failure.bad("could not allocate \(w)×\(h)") }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw Failure.bad("PNG encoding failed")
        }
        let n = (try cleanName(name, defaultExt: "png") as NSString).deletingPathExtension + ".png"
        try write(png, name: n, store: store)
        return Written(src: n, width: w, height: h)
    }

    private static func write(_ data: Data, name: String, store: ProjectStore) throws {
        try FileManager.default.createDirectory(at: store.assetsURL, withIntermediateDirectories: true)
        try data.write(to: store.assetsURL.appendingPathComponent(name), options: .atomic)
    }

    // MARK: Symbols

    public enum SymbolScope: String, Sendable { case project, library }

    /// Adds or replaces symbol `pack/id` in a pack file (`symbols/<pack>.json` in the project, or the user library).
    /// The path is validated (it must parse and be non-empty). Returns the symbol id.
    @discardableResult
    public static func saveSymbol(
        pack: String, id: String, name: String?, path: String, rim: String?, evenOdd: Bool,
        scope: SymbolScope, project: URL?
    ) throws -> String {
        func slug(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: "[^a-z0-9-]+", with: "-", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
        let p = slug(pack), i = slug(id)
        guard !p.isEmpty, !i.isEmpty else { throw Failure.bad("pack and id need letters or digits") }
        guard !["basic", "chess"].contains(p) else {
            throw Failure.bad("'\(p)' is a built-in pack; use your own pack name")
        }
        var item: [String: JSONValue] = ["id": .string(i), "name": .string(name ?? id), "path": .string(path)]
        if let rim { item["rim"] = .string(rim) }
        if evenOdd { item["fillRule"] = "evenodd" }
        do { _ = try SVGPath.sprite(item) } catch { throw Failure.bad("path: \(error)") }

        let dir: URL
        switch scope {
        case .project:
            guard let project else { throw Failure.bad("no project open") }
            dir = project.appendingPathComponent("symbols")
        case .library: dir = Symbols.userLibrary
        }
        let file = dir.appendingPathComponent("\(p).json")
        var symbols: [JSONValue] = []
        if let j = JSONFile.read(JSONValue.self, from: file) {
            symbols = (j["symbols"]?.array ?? []).filter { $0["id"]?.string != i }
        }
        symbols.append(.object(item))
        let pack: JSONValue = .object(["pack": .string(p), "symbols": .array(symbols)])
        try JSONFile.write(pack, to: file)
        // Touch the folder so the pack cache (keyed by folder date) reloads even within the same second.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: dir.path)
        return "\(p)/\(i)"
    }
}
