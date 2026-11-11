import Foundation

/// A reusable scene with parameters: `{{name}}` placeholders anywhere in the scene JSON
/// (a whole string `"{{value}}"` becomes the typed value; inside a longer string it is interpolated).
/// Canvas placeholders are always available: `{{W}}`, `{{H}}`, `{{CX}}`, `{{CY}}`.
///
/// Sources (later wins on id clashes): built-in, `~/Library/Application Support/Arclight/library/templates/*.json`,
/// and the project's `templates/*.json`.
public struct Template: Codable, Equatable, Sendable {
    public struct Param: Codable, Equatable, Sendable {
        public var name: String
        public var label: String?
        /// "text", "number", "color", "symbol", "json" (UI hint).
        public var kind: String?
        public var `default`: JSONValue?
        public var doc: String?
        public init(
            name: String, label: String? = nil, kind: String? = nil, default def: JSONValue? = nil, doc: String? = nil
        ) {
            self.name = name; self.label = label; self.kind = kind; self.default = def; self.doc = doc
        }
    }

    public var id: String
    public var name: String
    public var description: String?
    public var category: String?
    public var params: [Param]
    /// Scene JSON (its id is replaced on instantiation).
    public var scene: JSONValue
    /// Theme tokens the template expects; added to the project when missing (never overwritten).
    public var theme: [String: JSONValue]?

    public init(
        id: String, name: String, description: String? = nil, category: String? = nil, params: [Param],
        scene: JSONValue, theme: [String: JSONValue]? = nil
    ) {
        self.id = id; self.name = name; self.description = description; self.category = category
        self.params = params; self.scene = scene; self.theme = theme
    }
}

public enum Templates {
    public enum Scope: String, Sendable { case project, user }

    static var userDir: URL {
        AppPaths.library("templates")
    }

    static func load(dir: URL) -> [Template] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap {
            JSONFile.read(Template.self, from: $0)
        }
    }

    public static func all(project: URL?) -> [Template] {
        var list = BuiltInTemplates.all + load(dir: userDir)
        if let project { list += load(dir: project.appendingPathComponent("templates")) }
        var seen = Set<String>()
        return list.reversed().filter { seen.insert($0.id).inserted }.reversed()
    }

    public static func get(_ id: String, project: URL?) -> Template? { all(project: project).last { $0.id == id } }

    /// Builds a scene: parameters (missing ones fall back to defaults) and canvas size substituted.
    public static func instantiate(
        _ t: Template, params: [String: JSONValue], sceneId: String, canvas: (Int, Int)
    ) throws -> Scene {
        var values: [String: JSONValue] = [
            "W": .number(Double(canvas.0)), "H": .number(Double(canvas.1)),
            "CX": .number(Double(canvas.0) / 2), "CY": .number(Double(canvas.1) / 2),
        ]
        for p in t.params { if let d = p.default { values[p.name] = d } }
        for (k, v) in params {
            guard t.params.contains(where: { $0.name == k }) else {
                throw ModelError.invalid(
                    "template '\(t.id)' has no parameter '\(k)' — parameters: \(t.params.map(\.name).joined(separator: ", "))"
                )
            }
            values[k] = v
        }
        let filled = substitute(t.scene, values)
        var obj = filled.object ?? [:]
        obj["id"] = .string(sceneId)
        obj["rev"] = nil
        if obj["name"] == nil { obj["name"] = .string(t.name) }
        return try JSONValue.object(obj).decoded(as: Scene.self)
    }

    static func substitute(_ v: JSONValue, _ values: [String: JSONValue]) -> JSONValue {
        switch v {
        case .string(let s):
            guard s.contains("{{") else { return v }
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("{{"), trimmed.hasSuffix("}}"),
                trimmed.dropFirst(2).dropLast(2).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
            {
                let key = String(trimmed.dropFirst(2).dropLast(2))
                if let val = values[key] { return val }
            }
            var out = s
            for (k, val) in values where out.contains("{{\(k)}}") {
                let str: String
                switch val {
                case .string(let x): str = x
                case .number(let d): str = d.rounded() == d && abs(d) < 1e15 ? String(Int64(d)) : String(d)
                default:
                    str = (try? String(data: JSONFormat.compact().encode(val), encoding: .utf8)) ?? ""
                }
                out = out.replacingOccurrences(of: "{{\(k)}}", with: str)
            }
            return .string(out)
        case .array(let a): return .array(a.map { substitute($0, values) })
        case .object(let o): return .object(o.mapValues { substitute($0, values) })
        default: return v
        }
    }

    /// Turns an existing scene into a template. Each param names a target `"<layer>.<prop>"` (or `"scene.<field>"`);
    /// the current value there becomes the default and is replaced by `{{name}}`.
    public static func make(
        from scene: Scene, id: String, name: String, description: String?,
        params: [(param: Template.Param, target: String)]
    ) throws -> Template {
        var json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(scene))
        var obj = json.object ?? [:]
        obj["rev"] = nil
        obj["id"] = .string(id)
        var nodes = obj["nodes"]?.array ?? []
        var out: [Template.Param] = []
        for (p, target) in params {
            let parts = target.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                throw ModelError.invalid("target '\(target)' must be '<layer>.<property>' or 'scene.<field>'")
            }
            var param = p
            if parts[0] == "scene" {
                param.default = param.default ?? obj[parts[1]]
                obj[parts[1]] = .string("{{\(p.name)}}")
            } else {
                guard let i = nodes.firstIndex(where: { $0["id"]?.string == parts[0] }), var n = nodes[i].object else {
                    throw ModelError.notFound("layer '\(parts[0])'")
                }
                guard let cur = n[parts[1]] else {
                    throw ModelError.notFound("property '\(parts[1])' on '\(parts[0])'")
                }
                param.default = param.default ?? cur
                n[parts[1]] = .string("{{\(p.name)}}")
                nodes[i] = .object(n)
            }
            out.append(param)
        }
        obj["nodes"] = .array(nodes)
        json = .object(obj)
        return Template(id: id, name: name, description: description, params: out, scene: json)
    }

    public static func save(_ t: Template, scope: Scope, project: URL?) throws -> URL {
        try SafeName.component(t.id, what: "template id")
        let dir: URL
        switch scope {
        case .user: dir = userDir
        case .project:
            guard let project else { throw ModelError.invalid("no project open") }
            dir = project.appendingPathComponent("templates")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(t.id).json")
        try JSONFormat.pretty().encode(t).write(to: url, options: .atomic)
        return url
    }
}
