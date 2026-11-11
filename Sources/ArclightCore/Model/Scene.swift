import Foundation

/// A layer in a scene. JSON is flat: meta keys (`id`, `type`, `parent`, `name`, `in`, `out`)
/// plus any number of props, e.g. `{"id":"title","type":"text","text":"Hi","x":100,"opacity":{"k":[[0,0],[0.4,1]]}}`.
public struct Node: Codable, Equatable, Sendable {
    public var id: String
    public var type: String
    public var parent: String?
    public var name: String?
    /// Scene time (s) the node appears. Node-local time `t` is measured from here.
    public var start: Double?
    /// Scene time (s) the node disappears.
    public var end: Double?
    public var props: [String: Prop]

    public static let metaKeys: Set<String> = ["id", "type", "parent", "name", "in", "out"]
    public static let types: Set<String> = ["group", "text", "shape", "symbol", "image", "repeater", "light"]
    /// Old names still accepted when loading (rewritten on save).
    public static let typeAliases: [String: String] = ["instancer": "repeater"]

    public init(id: String, type: String, parent: String? = nil, props: [String: Prop] = [:]) {
        self.id = id; self.type = Node.typeAliases[type] ?? type; self.parent = parent; self.props = props
    }

    struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        id = try c.decode(String.self, forKey: Key("id"))
        let rawType = try c.decode(String.self, forKey: Key("type"))
        type = Node.typeAliases[rawType] ?? rawType
        parent = try c.decodeIfPresent(String.self, forKey: Key("parent"))
        name = try c.decodeIfPresent(String.self, forKey: Key("name"))
        start = try c.decodeIfPresent(Double.self, forKey: Key("in"))
        end = try c.decodeIfPresent(Double.self, forKey: Key("out"))
        var p: [String: Prop] = [:]
        for k in c.allKeys where !Node.metaKeys.contains(k.stringValue) {
            p[k.stringValue] = try c.decode(Prop.self, forKey: k)
        }
        props = p
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        try c.encode(id, forKey: Key("id"))
        try c.encode(type, forKey: Key("type"))
        try c.encodeIfPresent(parent, forKey: Key("parent"))
        try c.encodeIfPresent(name, forKey: Key("name"))
        try c.encodeIfPresent(start, forKey: Key("in"))
        try c.encodeIfPresent(end, forKey: Key("out"))
        for (k, v) in props { try c.encode(v, forKey: Key(k)) }
    }
}

public struct Scene: Codable, Equatable, Sendable {
    public var id: String
    public var name: String?
    public var duration: Double
    /// Overrides project size/fps when set.
    public var size: [Int]?
    public var fps: Double?
    public var background: Prop?
    /// 3D camera for nodes with `"3d": true` and repeaters:
    /// `{"position":[x,y,z],"target":[x,y,z],"fov":40,"roll":0,"dof":{"focus":1500,"blur":12,"range":0.5}}`.
    public var camera: Prop?
    /// Distance fog for the 3D layer: `{"color":"#000","near":1500,"far":5000}`.
    public var fog: Prop?
    /// Final grade: `{"exposure":0,"contrast":1,"saturation":1,"vignette":0.4,"grain":0.05,"bloom":{"intensity":0.6,"threshold":1}}`.
    public var post: Prop?
    /// Named points in time (e.g. beats of a voiceover) that layers, snapping and AI agents can refer to.
    public var markers: [Marker]?
    /// Reference audio (voiceover/music) played with the scene and mixed into exports.
    public var audio: AudioRef?
    public var nodes: [Node]
    /// Incremented on every saved change; used for conflict detection between editor and MCP.
    public var rev: Int

    public init(id: String, duration: Double = 5, nodes: [Node] = []) {
        self.id = id; self.duration = duration; self.nodes = nodes; self.rev = 0
    }

    enum CodingKeys: String, CodingKey {
        case id, name, duration, size, fps, background, camera, fog, post, markers, audio, nodes, rev
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 5
        size = try c.decodeIfPresent([Int].self, forKey: .size)
        fps = try c.decodeIfPresent(Double.self, forKey: .fps)
        background = try c.decodeIfPresent(Prop.self, forKey: .background)
        camera = try c.decodeIfPresent(Prop.self, forKey: .camera)
        fog = try c.decodeIfPresent(Prop.self, forKey: .fog)
        post = try c.decodeIfPresent(Prop.self, forKey: .post)
        markers = try c.decodeIfPresent([Marker].self, forKey: .markers)
        audio = try c.decodeIfPresent(AudioRef.self, forKey: .audio)
        nodes = try c.decodeIfPresent([Node].self, forKey: .nodes) ?? []
        rev = try c.decodeIfPresent(Int.self, forKey: .rev) ?? 0
    }

    public func node(_ id: String) -> Node? { nodes.first { $0.id == id } }

    public func marker(_ name: String) -> Marker? { markers?.first { $0.name == name } }
}

/// A named time in a scene: `{"name":"lock","t":3.4,"color":"#FFCC00"}`.
public struct Marker: Codable, Equatable, Sendable {
    public var name: String
    public var t: Double
    public var color: String?
    public init(name: String, t: Double, color: String? = nil) { self.name = name; self.t = t; self.color = color }
}

/// Reference audio: `{"src":"voice.wav","offset":0.5,"trim":0,"gain":1,"fadeIn":0,"fadeOut":0.3}`.
/// `offset` = scene time where the audio starts; `trim` = seconds skipped at the start of the file.
public struct AudioRef: Codable, Equatable, Sendable {
    public var src: String
    public var offset: Double?
    public var trim: Double?
    public var gain: Double?
    public var fadeIn: Double?
    public var fadeOut: Double?
    /// Silence the audio: left out of exports and muted in editor playback.
    public var mute: Bool?
    public init(src: String) { self.src = src }
}

public struct Project: Codable, Equatable, Sendable {
    public var name: String
    public var size: [Int]
    public var fps: Double
    /// Design tokens referenced from props as `"$name"` (colors, fonts, numbers, easings).
    public var theme: [String: JSONValue]
    /// Scene order for the timeline/export.
    public var scenes: [String]

    public init(
        name: String, size: [Int] = [1920, 1080], fps: Double = 30, theme: [String: JSONValue] = Project.defaultTheme
    ) {
        self.name = name; self.size = size; self.fps = fps; self.theme = theme; self.scenes = []
    }

    public static let defaultTheme: [String: JSONValue] = [
        "bg": "#000000", "fg": "#F2EFE6", "muted": "#7A7A7A", "accent": "#FFFFFF",
        "display": "HelveticaNeue-CondensedBlack", "body": "HelveticaNeue-Medium",
    ]

    enum CodingKeys: String, CodingKey { case name, size, fps, theme, scenes }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        size = try c.decodeIfPresent([Int].self, forKey: .size) ?? [1920, 1080]
        fps = try c.decodeIfPresent(Double.self, forKey: .fps) ?? 30
        theme = try c.decodeIfPresent([String: JSONValue].self, forKey: .theme) ?? Project.defaultTheme
        scenes = try c.decodeIfPresent([String].self, forKey: .scenes) ?? []
    }

    public func size(for scene: Scene) -> (Int, Int) {
        let s = scene.size ?? size
        return (s.count > 0 ? s[0] : 1920, s.count > 1 ? s[1] : 1080)
    }
}
