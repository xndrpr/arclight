import Foundation

/// A still image on a thumbnail page (a YouTube thumbnail, a Shorts cover, a variant of either). Layers are the same
/// `Node` JSON as motion scenes and render through the same renderer (see `asScene`); keyframes are allowed but the
/// artboard is always rendered at t = 0.
///
/// JSON: `{"id":"a","name":"A","x":0,"y":0,"size":[1280,720],"background":"$bg","nodes":[…]}`
public struct Artboard: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    /// Position on the page's board (px, top-left), so artboards sit side by side like Figma frames.
    public var x: Double
    public var y: Double
    public var size: [Int]
    public var background: Prop?
    public var post: Prop?
    public var nodes: [Node]

    public static let youtubeSize = [1280, 720]

    public init(id: String, name: String? = nil, x: Double = 0, y: Double = 0, size: [Int] = Artboard.youtubeSize,
        nodes: [Node] = [])
    {
        self.id = id; self.name = name; self.x = x; self.y = y; self.size = size; self.nodes = nodes
    }

    enum CodingKeys: String, CodingKey { case id, name, x, y, size, background, post, nodes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0
        size = try c.decodeIfPresent([Int].self, forKey: .size) ?? Artboard.youtubeSize
        background = try c.decodeIfPresent(Prop.self, forKey: .background)
        post = try c.decodeIfPresent(Prop.self, forKey: .post)
        nodes = try c.decodeIfPresent([Node].self, forKey: .nodes) ?? []
    }

    public var width: Int { size.count > 0 ? size[0] : Artboard.youtubeSize[0] }
    public var height: Int { size.count > 1 ? size[1] : Artboard.youtubeSize[1] }

    /// Id of the scene an artboard is edited and rendered as: `<thumbnail>~<artboard>`. `~` never occurs in scene ids
    /// (`SafeName.id`), so it can't collide with a real scene.
    public static func sceneId(thumbnail: String, artboard: String) -> String { "\(thumbnail)~\(artboard)" }

    /// The artboard as a one-second scene of its own size, rendered at t = 0. Everything that works on scenes
    /// (renderer, bounds, validation, `SceneOps`, the editor's canvas and inspector) works on artboards through this.
    public func asScene(thumbnail: String, rev: Int = 0) -> Scene {
        var s = Scene(id: Artboard.sceneId(thumbnail: thumbnail, artboard: id), duration: 1, nodes: nodes)
        s.name = name
        s.size = [width, height]
        s.background = background
        s.post = post
        s.rev = rev
        return s
    }

    /// Takes back the editable parts of a scene made by `asScene` (layers, name, size, background, grade).
    public mutating func update(from s: Scene) {
        nodes = s.nodes
        name = s.name
        if let z = s.size, z.count == 2 { size = z }
        background = s.background
        post = s.post
    }
}

/// How a thumbnail gets its design tokens: shared with the project (default), or a detached copy that no longer
/// follows project theme changes.
public enum ThemeLink: Codable, Equatable, Sendable {
    case project
    case detached([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self), s == "project" { self = .project; return }
        struct D: Decodable { var tokens: [String: JSONValue]? }
        let d = try c.decode(D.self)
        self = .detached(d.tokens ?? [:])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .project: try c.encode("project")
        case .detached(let t): try c.encode(["detached": JSONValue.bool(true), "tokens": .object(t)])
        }
    }

    public var isDetached: Bool { if case .detached = self { return true }; return false }
}

/// A thumbnail page: one or more artboards (variants, formats) laid out on a board, stored as `thumbnails/<id>.json`.
public struct Thumbnail: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var artboards: [Artboard]
    public var theme: ThemeLink
    /// Reference pictures (asset names) kept with the page for inspiration; never exported.
    public var references: [String]?
    /// Incremented on every saved change, like `Scene.rev`.
    public var rev: Int

    public init(id: String, name: String? = nil, artboards: [Artboard] = [], theme: ThemeLink = .project) {
        self.id = id; self.name = name; self.artboards = artboards; self.theme = theme; self.rev = 0
    }

    enum CodingKeys: String, CodingKey { case id, name, artboards, theme, references, rev }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        artboards = try c.decodeIfPresent([Artboard].self, forKey: .artboards) ?? []
        theme = try c.decodeIfPresent(ThemeLink.self, forKey: .theme) ?? .project
        references = try c.decodeIfPresent([String].self, forKey: .references)
        rev = try c.decodeIfPresent(Int.self, forKey: .rev) ?? 0
    }

    public func artboard(_ id: String?) -> Artboard? {
        guard let id else { return artboards.first }
        return artboards.first { $0.id == id }
    }

    public func index(of artboard: String) throws -> Int {
        guard let i = artboards.firstIndex(where: { $0.id == artboard }) else {
            throw ModelError.notFound("artboard '\(artboard)' in thumbnail '\(id)'")
        }
        return i
    }

    /// An artboard id not used in this thumbnail: `base`, `base-2`, …
    public func uniqueArtboardId(_ base: String) -> String {
        let ids = Set(artboards.map(\.id))
        if !ids.contains(base) { return base }
        var k = 2
        while ids.contains("\(base)-\(k)") { k += 1 }
        return "\(base)-\(k)"
    }

    /// Where a new artboard goes: to the right of the rightmost one, with a gap.
    public func nextArtboardOrigin(gap: Double = 120) -> (Double, Double) {
        guard let last = artboards.max(by: { $0.x + Double($0.width) < $1.x + Double($1.width) }) else { return (0, 0) }
        return (last.x + Double(last.width) + gap, last.y)
    }
}

extension Project {
    /// The tokens a thumbnail renders with: the project theme, or its detached copy laid over it (tokens the copy
    /// lacks still come from the project, so a detached thumbnail never loses a token it references).
    public func theme(for thumbnail: Thumbnail) -> [String: JSONValue] {
        switch thumbnail.theme {
        case .project: return theme
        case .detached(let t): return theme.merging(t) { _, mine in mine }
        }
    }

    /// This project as seen by a thumbnail's renderer: same everything, with the thumbnail's theme.
    public func rendering(_ thumbnail: Thumbnail) -> Project {
        var p = self
        p.theme = theme(for: thumbnail)
        return p
    }
}
