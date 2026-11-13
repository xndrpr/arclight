import Foundation

/// A still image on a preview page (a YouTube thumbnail, a Shorts cover, a variant of either). Layers are the same
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

    /// Id of the scene an artboard is edited and rendered as: `<preview>~<artboard>`. `~` never occurs in scene ids
    /// (`SafeName.id`), so it can't collide with a real scene.
    public static func sceneId(preview: String, artboard: String) -> String { "\(preview)~\(artboard)" }

    /// The artboard as a one-second scene of its own size, rendered at t = 0. Everything that works on scenes
    /// (renderer, bounds, validation, `SceneOps`, the editor's canvas and inspector) works on artboards through this.
    public func asScene(preview: String, rev: Int = 0) -> Scene {
        var s = Scene(id: Artboard.sceneId(preview: preview, artboard: id), duration: 1, nodes: nodes)
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

/// How a preview gets its design tokens: shared with the project (default), or a detached copy that no longer
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

/// A preview page: one or more artboards (variants, formats) laid out on a board, stored as `previews/<id>.json`.
public struct Preview: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var artboards: [Artboard]
    public var theme: ThemeLink
    /// Incremented on every saved change, like `Scene.rev`.
    public var rev: Int

    public init(id: String, name: String? = nil, artboards: [Artboard] = [], theme: ThemeLink = .project) {
        self.id = id; self.name = name; self.artboards = artboards; self.theme = theme; self.rev = 0
    }

    enum CodingKeys: String, CodingKey { case id, name, artboards, theme, rev }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        artboards = try c.decodeIfPresent([Artboard].self, forKey: .artboards) ?? []
        theme = try c.decodeIfPresent(ThemeLink.self, forKey: .theme) ?? .project
        rev = try c.decodeIfPresent(Int.self, forKey: .rev) ?? 0
    }

    public func artboard(_ id: String?) -> Artboard? {
        guard let id else { return artboards.first }
        return artboards.first { $0.id == id }
    }

    public func index(of artboard: String) throws -> Int {
        guard let i = artboards.firstIndex(where: { $0.id == artboard }) else {
            throw ModelError.notFound("artboard '\(artboard)' in preview '\(id)'")
        }
        return i
    }

    /// An artboard id not used in this preview: `base`, `base-2`, …
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
    /// The tokens a preview renders with: the project theme, or its detached copy laid over it (tokens the copy
    /// lacks still come from the project, so a detached preview never loses a token it references).
    public func theme(for preview: Preview) -> [String: JSONValue] {
        switch preview.theme {
        case .project: return theme
        case .detached(let t): return theme.merging(t) { _, mine in mine }
        }
    }

    /// This project as seen by a preview's renderer: same everything, with the preview's theme.
    public func rendering(_ preview: Preview) -> Project {
        var p = self
        p.theme = theme(for: preview)
        return p
    }
}
