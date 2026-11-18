import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file the user attached to a chat message. A copy is kept at `<project>/.arclight/chat-files/<id>/<name>`, so the
/// transcript can show it after the project is reopened and the AI can bring it into the project (asset_import).
public struct ChatAttachment: Codable, Equatable, Identifiable, Sendable {
    /// image: the model sees it. pdf: read as a document. text: its contents go in the message. file: only its path
    /// (video, audio, fonts…), for the AI to import.
    public enum Kind: String, Codable, Sendable { case image, pdf, text, file }

    public var id: String
    public var name: String
    public var kind: Kind
    /// Absolute path of the kept copy.
    public var path: String
    public var size: Int

    public init(id: String = UUID().uuidString, name: String, kind: Kind, path: String, size: Int) {
        self.id = id; self.name = name; self.kind = kind; self.path = path; self.size = size
    }

    /// The API takes PDFs up to 32 MB; anything bigger isn't worth holding in a message.
    public static let maxBytes = 30_000_000
    /// Longest edge of an image as the model sees it (bigger costs tokens without helping).
    static let maxImageEdge = 1568
    /// Text files longer than this are cut (the copy on disk stays whole).
    static let maxTextChars = 150_000

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case tooBig(String)
        case unreadable(String)
        public var description: String {
            switch self {
            case .tooBig(let n): return "\(n) is too big to attach (30 MB at most)."
            case .unreadable(let n): return "Couldn't read \(n)."
            }
        }
    }

    public static func folder(_ project: URL) -> URL {
        project.appendingPathComponent(ProjectLayout.hiddenFolder).appendingPathComponent("chat-files")
    }

    /// Copies `url` into the project's chat files.
    public static func store(file url: URL, project: URL) throws -> ChatAttachment {
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else { throw Failure.tooBig(name) }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable(name) }
        return try store(data: data, name: name, project: project)
    }

    /// Writes `data` (a pasted image, a dropped file) into the project's chat files.
    public static func store(data: Data, name: String, project: URL) throws -> ChatAttachment {
        guard data.count <= maxBytes else { throw Failure.tooBig(name) }
        let id = UUID().uuidString
        let safe = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let dir = folder(project).appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(safe.isEmpty ? "file" : safe)
        try data.write(to: dest)
        return ChatAttachment(id: id, name: safe, kind: kind(name: safe, data: data), path: dest.path, size: data.count)
    }

    /// Removes kept copies no longer needed (a new chat), except `keep`.
    public static func prune(project: URL, keep: [ChatAttachment]) {
        let fm = FileManager.default
        let dir = folder(project)
        let kept = Set(keep.map(\.id))
        for d in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !kept.contains(d) {
            try? fm.removeItem(at: dir.appendingPathComponent(d))
        }
    }

    static func kind(name: String, data: Data) -> Kind {
        let ext = (name as NSString).pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        if let t = UTType(filenameExtension: ext) {
            if t.conforms(to: .image), !t.conforms(to: .svg) { return .image }
            if t.conforms(to: .audiovisualContent) || t.conforms(to: .font) { return .file }
        }
        if data.count <= 2_000_000, !data.prefix(8000).contains(0), String(data: data, encoding: .utf8) != nil {
            return .text
        }
        return .file
    }

    var url: URL { URL(fileURLWithPath: path) }

    /// The message content for these attachments, in Messages API form: images and PDFs as blocks the model reads,
    /// text files inline, and a note with where each copy is (so the AI can import one into the project).
    public static func contentBlocks(_ list: [ChatAttachment]) -> [JSONValue] {
        guard !list.isEmpty else { return [] }
        var blocks: [JSONValue] = []
        var lines: [String] = []
        for a in list {
            var note = "- \(a.name): \(a.path)"
            switch a.kind {
            case .image:
                if let (data, type) = modelImage(a.url) {
                    blocks.append([
                        "type": "image",
                        "source": [
                            "type": "base64", "media_type": .string(type), "data": .string(data.base64EncodedString()),
                        ],
                    ])
                } else {
                    note += " (couldn't be read as an image)"
                }
            case .pdf:
                if let d = try? Data(contentsOf: a.url) {
                    blocks.append([
                        "type": "document", "title": .string(a.name),
                        "source": [
                            "type": "base64", "media_type": "application/pdf", "data": .string(d.base64EncodedString()),
                        ],
                    ])
                }
            case .text:
                if let d = try? Data(contentsOf: a.url) {
                    var s = String(decoding: d, as: UTF8.self)
                    if s.count > maxTextChars { s = String(s.prefix(maxTextChars)) + "\n… (cut here)" }
                    blocks.append(["type": "text", "text": .string("<file name=\"\(a.name)\">\n\(s)\n</file>")])
                }
            case .file:
                note += " (not readable in the chat; import it to use it)"
            }
            lines.append(note)
        }
        let header =
            "The user attached \(list.count == 1 ? "this file" : "these files"). Copies are kept on this Mac; "
            + "asset_import {\"path\": …} brings one into the project:"
        blocks.append(["type": "text", "text": .string(([header] + lines).joined(separator: "\n"))])
        return blocks
    }

    /// The image as the model should get it: at most `maxImageEdge` on the long side, PNG when it has transparency
    /// (else JPEG). HEIC, TIFF and the rest are converted.
    static func modelImage(_ url: URL) -> (Data, String)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImageEdge,
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let alpha: Bool
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: alpha = false
        default: alpha = true
        }
        let type = alpha ? UTType.png : UTType.jpeg
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, alpha ? "image/png" : "image/jpeg")
    }
}
