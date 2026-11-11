import ArclightCore
import Foundation

extension LibraryModel {
    // MARK: Template files (project / user)

    private static var userTemplatesDir: URL {
        AppPaths.library("templates")
    }

    struct TemplateFile: Identifiable {
        var template: Template
        var url: URL
        var scope: Templates.Scope
        var id: String { url.path }
    }

    /// Templates saved as files (project first, then the user library). Built-ins are not files and can't be deleted.
    static func templateFiles(project: URL?) -> [TemplateFile] {
        func load(_ dir: URL, _ scope: Templates.Scope) -> [TemplateFile] {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }.compactMap { u in
                guard let d = try? Data(contentsOf: u), let t = try? JSONDecoder().decode(Template.self, from: d) else {
                    return nil
                }
                return TemplateFile(template: t, url: u, scope: scope)
            }
        }
        return (project.map { load($0.appendingPathComponent("templates"), .project) } ?? [])
            + load(userTemplatesDir, .user)
    }

    /// Theme tokens the template expects that the project lacks (never overwrites).
    static func missingTokens(_ t: Template, in project: Project) -> [String: JSONValue] {
        (t.theme ?? [:]).filter { project.theme[$0.key] == nil }
    }

    // MARK: Insert a template's layers into an existing scene

    /// Inserts `source`'s layers into `target`. Every id gets `prefix-` (made unique against the target),
    /// parents and quoted id references inside expressions (`litCount('crowd')`) follow. Camera, fog and post
    /// are copied only when the target has none; the scene grows to fit a longer template.
    /// Returns the new scene and the ids of the inserted layers.
    static func insert(_ source: Scene, into target: Scene, prefix: String) -> (scene: Scene, ids: [String]) {
        var out = target
        var probe = target
        var rename: [String: String] = [:]
        for n in source.nodes {
            let nid = SceneOps.uniqueId("\(prefix)-\(n.id)", in: probe)
            rename[n.id] = nid
            probe.nodes.append(Node(id: nid, type: "group"))
        }
        let added = source.nodes.map { n -> Node in
            var c = n
            c.id = rename[n.id]!
            c.parent = n.parent.flatMap { rename[$0] }
            c.props = c.props.mapValues { renameRefs($0, rename) }
            return c
        }
        out.nodes.append(contentsOf: added)
        if out.camera == nil, let c = source.camera { out.camera = renameRefs(c, rename) }
        if out.fog == nil, let f = source.fog { out.fog = f }
        if out.post == nil, let p = source.post { out.post = p }
        out.duration = max(out.duration, source.duration)
        return (out, added.map(\.id))
    }

    /// Rewrites `'old'` / `"old"` id references inside expression strings.
    private static func renameRefs(_ p: Prop, _ rename: [String: String]) -> Prop {
        switch p {
        case .expr(let s): return .expr(renameInString(s, rename))
        case .value(let v): return .value(renameInJSON(v, rename))
        case .keys: return p
        }
    }

    private static func renameInJSON(_ v: JSONValue, _ rename: [String: String]) -> JSONValue {
        switch v {
        case .object(let o):
            // Nested expressions, e.g. instance: {lit: {expr: "…litCount('crowd')…"}}.
            if o.count == 1, let e = o["expr"]?.string { return .object(["expr": .string(renameInString(e, rename))]) }
            return .object(o.mapValues { renameInJSON($0, rename) })
        case .array(let a): return .array(a.map { renameInJSON($0, rename) })
        default: return v
        }
    }

    private static func renameInString(_ s: String, _ rename: [String: String]) -> String {
        var out = s
        for (old, new) in rename {
            out = out.replacingOccurrences(of: "'\(old)'", with: "'\(new)'").replacingOccurrences(
                of: "\"\(old)\"", with: "\"\(new)\"")
        }
        return out
    }

    /// Id prefix for layers inserted from a template ("lower-third" → "lower-third").
    static func prefix(for t: Template) -> String {
        let s = slug(t.id)
        return s.isEmpty ? "t" : s
    }

    // MARK: Save as template: parameter picker

    /// One value in a scene that can become a template parameter.
    struct ParamCandidate: Identifiable, Equatable {
        /// Layer id, or "scene".
        var layer: String
        /// Property ("text", "value", "symbol"…).
        var prop: String
        /// Path into the layer's JSON (["text"], ["value", "k", 2, 1] for the last keyframe, ["items", 0, "symbol"]).
        var path: [PathItem]
        var kind: String
        var current: JSONValue
        var label: String
        var id: String { layer + "/" + path.map(\.description).joined(separator: ".") }

        /// `<layer>_<prop>` with only letters, digits and `_` (so a whole-string placeholder keeps its type).
        var paramName: String {
            let raw = layer == "scene" ? prop : "\(layer)_\(prop)"
            return raw.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
        }
        /// Template.make target, when the value is a whole top-level prop.
        var target: String? { path.count == 1 ? "\(layer).\(prop)" : nil }
    }

    enum PathItem: Hashable, CustomStringConvertible {
        case key(String), index(Int)
        var description: String {
            switch self {
            case .key(let k): return k;
            case .index(let i): return String(i)
            }
        }
    }

    private static let textProps = ["text", "src", "font"]
    private static let numberProps = ["value", "size"]
    private static let colorProps = ["color", "fill", "stroke"]

    /// Simple, user-facing values of a scene: texts, counter values, colours, sources, repeater symbols.
    static func candidates(_ scene: Scene) -> [ParamCandidate] {
        var out: [ParamCandidate] = []
        for n in scene.nodes {
            for prop in textProps + numberProps + colorProps {
                guard let p = n.props[prop] else { continue }
                let kind = textProps.contains(prop) ? "text" : numberProps.contains(prop) ? "number" : "color"
                switch p {
                case .value(let v) where v.string != nil || v.double != nil:
                    out.append(
                        ParamCandidate(
                            layer: n.id, prop: prop, path: [.key(prop)], kind: kind, current: v,
                            label: "\(n.id) · \(prop)"))
                case .keys(let ks) where !ks.isEmpty && (ks.last!.v.double != nil || ks.last!.v.string != nil):
                    out.append(
                        ParamCandidate(
                            layer: n.id, prop: prop, path: [.key(prop), .key("k"), .index(ks.count - 1), .index(1)],
                            kind: kind, current: ks.last!.v, label: "\(n.id) · \(prop) (end)"))
                default: break
                }
            }
            if n.type == "repeater", case .value(let items)? = n.props["items"], let arr = items.array {
                for (i, it) in arr.enumerated() {
                    guard let sym = it["symbol"], sym.string != nil else { continue }
                    let prop = arr.count == 1 ? "symbol" : "symbol\(i + 1)"
                    out.append(
                        ParamCandidate(
                            layer: n.id, prop: prop, path: [.key("items"), .index(i), .key("symbol")],
                            kind: "symbol", current: sym, label: "\(n.id) · \(prop)"))
                }
            }
        }
        if case .value(let bg)? = scene.background, bg.string != nil {
            out.append(
                ParamCandidate(
                    layer: "scene", prop: "background", path: [.key("background")], kind: "color", current: bg,
                    label: "scene · background"))
        }
        return out
    }

    /// Builds a template from the picked candidates: whole props go through `Templates.make`; nested values
    /// (last keyframe, repeater item symbols) are replaced by `{{name}}` afterwards with their current value as default.
    static func makeTemplate(
        from scene: Scene, id: String, name: String, description: String?, category: String?,
        picks: [ParamCandidate]
    ) throws -> Template {
        var used = Set<String>()
        func unique(_ n: String) -> String {
            var k = 2, s = n
            while used.contains(s) { s = "\(n)\(k)"; k += 1 }
            used.insert(s); return s
        }
        var direct: [(param: Template.Param, target: String)] = []
        var nested: [(Template.Param, ParamCandidate)] = []
        var names: [String] = []
        for c in picks {
            let p = Template.Param(name: unique(c.paramName), label: label(c), kind: c.kind, default: c.current)
            names.append(p.name)
            if c.layer == "scene" {
                direct.append((p, "scene.\(c.prop)"))
            } else if let t = c.target {
                direct.append((p, t))
            } else {
                nested.append((p, c))
            }
        }
        var t = try Templates.make(from: scene, id: id, name: name, description: description, params: direct)
        t.category = category?.isEmpty == false ? category : nil
        if !nested.isEmpty {
            var obj = t.scene.object ?? [:]
            var nodes = obj["nodes"]?.array ?? []
            for (p, c) in nested {
                guard let i = nodes.firstIndex(where: { $0["id"]?.string == c.layer }) else {
                    throw ModelError.notFound("layer '\(c.layer)'")
                }
                nodes[i] = setting(nodes[i], c.path[...], .string("{{\(p.name)}}"))
                t.params.append(p)
            }
            obj["nodes"] = .array(nodes)
            t.scene = .object(obj)
        }
        let order = Dictionary(uniqueKeysWithValues: names.enumerated().map { ($1, $0) })
        t.params.sort { (order[$0.name] ?? 0) < (order[$1.name] ?? 0) }
        return t
    }

    private static func label(_ c: ParamCandidate) -> String {
        let p = c.prop.prefix(1).uppercased() + c.prop.dropFirst()
        return c.layer == "scene" ? p : "\(c.layer) \(c.prop)"
    }

    private static func setting(_ v: JSONValue, _ path: ArraySlice<PathItem>, _ new: JSONValue) -> JSONValue {
        guard let first = path.first else { return new }
        switch (first, v) {
        case (.key(let k), .object(var o)):
            o[k] = setting(o[k] ?? .null, path.dropFirst(), new); return .object(o)
        case (.index(let i), .array(var a)) where a.indices.contains(i):
            a[i] = setting(a[i], path.dropFirst(), new); return .array(a)
        default: return v
        }
    }

    /// Template id from a display name ("Brand stat" → "brand-stat"); ASCII only, may be empty.
    static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        return s.split(separator: "-").joined(separator: "-")
    }
}
