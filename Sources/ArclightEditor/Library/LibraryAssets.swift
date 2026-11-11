import ArclightCore
import Foundation

extension LibraryModel {

    enum AssetKind: String, CaseIterable, Sendable {
        case image, audio, font, symbols, template

        /// Project subfolder a file of this kind is copied into.
        var folder: String {
            switch self {
            case .image, .audio: return "assets"
            case .font: return "fonts"
            case .symbols: return "symbols"
            case .template: return "templates"
            }
        }

        private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "heic", "tif", "tiff", "bmp", "webp"]
        private static let audioExts: Set<String> = ["wav", "mp3", "m4a", "aac", "aif", "aiff", "caf", "flac"]
        private static let fontExts: Set<String> = ["ttf", "otf", "ttc"]

        /// Classifies by extension. `.json` is a symbol pack unless its content looks like a template
        /// (pass `contents` to decide; without it a JSON file counts as a symbol pack).
        static func classify(_ url: URL, contents: Data? = nil) -> AssetKind? {
            let ext = url.pathExtension.lowercased()
            if imageExts.contains(ext) { return .image }
            if audioExts.contains(ext) { return .audio }
            if fontExts.contains(ext) { return .font }
            if ext == "json" {
                if let d = contents, let o = (try? JSONDecoder().decode(JSONValue.self, from: d))?.object,
                    o["scene"] != nil, o["symbols"] == nil
                {
                    return .template
                }
                return .symbols
            }
            return nil
        }
    }

    /// Copies a file into the right project folder (`assets/`, `fonts/`, `symbols/`, `templates/`) and returns
    /// its kind and destination. Fonts are registered right away.
    @discardableResult
    static func importFile(_ src: URL, into project: URL) throws -> (AssetKind, URL) {
        guard
            let kind = AssetKind.classify(
                src, contents: src.pathExtension.lowercased() == "json" ? try? Data(contentsOf: src) : nil)
        else {
            throw ModelError.invalid("\(src.lastPathComponent): unsupported file type")
        }
        let fm = FileManager.default
        let dir = project.appendingPathComponent(kind.folder)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(src.lastPathComponent)
        if dest.standardizedFileURL != src.standardizedFileURL {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: src, to: dest)
        }
        if kind == .font { ProjectStore.registerFonts(in: project) }
        return (kind, dest)
    }

    /// Files of a kind in the project, sorted by name.
    static func files(_ kind: AssetKind, in project: URL) -> [URL] {
        let dir = project.appendingPathComponent(kind.folder)
        let all =
            (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return all.filter {
            AssetKind.classify($0, contents: kind == .template || kind == .symbols ? try? Data(contentsOf: $0) : nil)
                == kind
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}
