import Foundation

/// Batch edits applied atomically to a scene. Designed for agents: small payloads, many edits per call.
///
/// Ops (every op is a JSON object with an `op` field):
/// - `{"op":"add","node":{...},"before"|"after":"id"}` — insert (default: on top of everything).
/// - `{"op":"set","id":"x"|"ids":[...],"size":120,"fill":null}` — merge props/meta; `null` removes.
/// - `{"op":"key","id":"x","prop":"opacity","keys":[[0,0],[0.5,1,"outCubic"]]}` — merge keyframes by time
///   (turns a constant into keyframes; add `"replace":true` to overwrite).
/// - `{"op":"remove","id"|"ids"}` — removes nodes and their descendants.
/// - `{"op":"move","id":"x","before"|"after":"y"}` or `{"op":"move","id":"x","index":0}` — reorder (draw order).
/// - `{"op":"duplicate","id":"x","as":"y", ...props}` — copies a node (and its subtree) with prop overrides.
/// - `{"op":"shift","id"|"ids","by":0.5}` — moves nodes in time (in/out).
/// - `{"op":"scene","duration":6,"background":"#111","name":"..."}` — scene-level fields.
public enum SceneOps {
    public struct Result {
        public var scene: Scene
        public var changed: [String]
        public var summary: String
    }

    public static func apply(_ ops: [JSONValue], to scene: Scene) throws -> Result {
        var s = scene
        var changed: [String] = []
        var summary: [String] = []
        for (i, op) in ops.enumerated() {
            guard let o = op.object, let kind = o["op"]?.string else {
                throw ModelError.invalid("op \(i): missing 'op'")
            }
            do {
                let ids = try apply(kind, o, &s)
                changed += ids
                summary.append("\(kind) \(ids.prefix(3).joined(separator: ","))\(ids.count > 3 ? "…" : "")")
            } catch {
                throw ModelError.invalid("op \(i) (\(kind)): \(error)")
            }
        }
        var seen = Set<String>()
        return Result(
            scene: s, changed: changed.filter { seen.insert($0).inserted }, summary: summary.joined(separator: "; "))
    }

    /// Editor-style edit: sets `prop` on node `id`. If the prop is keyframed, inserts or replaces the key at
    /// node-local time `t` (auto-key); otherwise sets the constant. Expressions are replaced by the value.
    public static func setProp(
        _ scene: inout Scene, id: String, prop: String, value: JSONValue, localTime t: Double,
        ease: Easing? = nil
    ) {
        guard let i = scene.nodes.firstIndex(where: { $0.id == id }) else { return }
        if case .keys(var ks)? = scene.nodes[i].props[prop] {
            let ft = (t * 1000).rounded() / 1000
            if let k = ks.firstIndex(where: { abs($0.t - ft) < 1e-4 }) {
                ks[k].v = value; if let ease { ks[k].ease = ease }
            } else {
                ks.append(Keyframe(t: ft, v: value, ease: ease ?? ks.last?.ease)); ks.sort { $0.t < $1.t }
            }
            scene.nodes[i].props[prop] = .keys(ks)
        } else {
            scene.nodes[i].props[prop] = .value(value)
        }
    }

    /// Toggles a keyframe at node-local time `t` holding `current` (turning a constant into keyframes, or
    /// removing the key; the last key removed leaves a constant).
    public static func toggleKey(
        _ scene: inout Scene, id: String, prop: String, current: JSONValue, localTime t: Double
    ) {
        guard let i = scene.nodes.firstIndex(where: { $0.id == id }) else { return }
        let ft = (t * 1000).rounded() / 1000
        switch scene.nodes[i].props[prop] {
        case .keys(var ks)?:
            if let k = ks.firstIndex(where: { abs($0.t - ft) < 1e-4 }) {
                ks.remove(at: k)
                scene.nodes[i].props[prop] = ks.isEmpty ? .value(current) : .keys(ks)
            } else {
                ks.append(Keyframe(t: ft, v: current, ease: ks.last?.ease)); ks.sort { $0.t < $1.t }
                scene.nodes[i].props[prop] = .keys(ks)
            }
        default:
            scene.nodes[i].props[prop] = .keys([Keyframe(t: ft, v: current)])
        }
    }

    /// A node id not used in the scene: `base`, `base-2`, `base-3`, …
    public static func uniqueId(_ base: String, in scene: Scene) -> String {
        let ids = Set(scene.nodes.map(\.id))
        if !ids.contains(base) { return base }
        var k = 2
        while ids.contains("\(base)-\(k)") { k += 1 }
        return "\(base)-\(k)"
    }

    static func ids(_ o: [String: JSONValue]) throws -> [String] {
        if let a = o["ids"]?.array { return a.compactMap(\.string) }
        if let id = o["id"]?.string { return [id] }
        throw ModelError.invalid("needs 'id' or 'ids'")
    }

    static func index(_ s: Scene, _ id: String) throws -> Int {
        guard let i = s.nodes.firstIndex(where: { $0.id == id }) else { throw ModelError.notFound("node '\(id)'") }
        return i
    }

    static func descendants(_ s: Scene, of id: String) -> [String] {
        var out: [String] = [], frontier = [id]
        while let cur = frontier.popLast() {
            for n in s.nodes where n.parent == cur { out.append(n.id); frontier.append(n.id) }
        }
        return out
    }

    /// A scene duration from outside: at most `SafeNumber.maxDuration` (a duration <= 0 is left for the validator,
    /// which reports it with the scene's other problems).
    public static func duration(_ d: Double) throws -> Double {
        guard !d.isNaN, d <= SafeNumber.maxDuration else {
            throw ModelError.invalid("duration must be at most \(SafeNumber.describe(SafeNumber.maxDuration)) seconds")
        }
        return d
    }

    static func insertionIndex(_ o: [String: JSONValue], _ s: Scene) throws -> Int {
        if let b = o["before"]?.string { return try index(s, b) }
        if let a = o["after"]?.string { return try index(s, a) + 1 }
        if let i = o["index"]?.double { return try SafeNumber.clampedInt(i, "index", to: 0...s.nodes.count) }
        return s.nodes.count
    }

    public static func decodeNode(_ v: JSONValue) throws -> Node {
        try v.decoded(as: Node.self)
    }

    /// Applies prop/meta fields onto a node; `null` deletes.
    static func merge(_ fields: [String: JSONValue], into n: inout Node) throws {
        for (k, v) in fields where k != "op" && k != "id" && k != "ids" && k != "as" {
            switch k {
            case "type":
                guard let t = v.string else { throw ModelError.invalid("type must be a string") };
                n.type = Node.typeAliases[t] ?? t
            case "parent": n.parent = v.string
            case "name": n.name = v.string
            case "in": n.start = v.double
            case "out": n.end = v.double
            default:
                if case .null = v { n.props[k] = nil } else { n.props[k] = try Prop(json: v) }
            }
        }
    }

    static func apply(_ kind: String, _ o: [String: JSONValue], _ s: inout Scene) throws -> [String] {
        switch kind {
        case "add":
            guard let nv = o["node"] else { throw ModelError.invalid("needs 'node'") }
            let n = try decodeNode(nv)
            if s.nodes.contains(where: { $0.id == n.id }) { throw ModelError.invalid("id '\(n.id)' already exists") }
            s.nodes.insert(n, at: try insertionIndex(o, s))
            return [n.id]

        case "set":
            let targets = try ids(o)
            for id in targets { let i = try index(s, id); try merge(o, into: &s.nodes[i]) }
            return targets

        case "key":
            guard let id = o["id"]?.string, let prop = o["prop"]?.string, let keys = o["keys"]?.array else {
                throw ModelError.invalid("needs id, prop, keys")
            }
            let i = try index(s, id)
            let new = try keys.map(Keyframe.init(json:))
            var existing: [Keyframe] = []
            if o["replace"]?.bool != true {
                switch s.nodes[i].props[prop] {
                case .keys(let ks)?: existing = ks
                case .value(let v)?: existing = [Keyframe(t: 0, v: v)]
                default: break
                }
            }
            let newTimes = Set(new.map(\.t))
            s.nodes[i].props[prop] = .keys((existing.filter { !newTimes.contains($0.t) } + new).sorted { $0.t < $1.t })
            return [id]

        case "remove":
            let targets = try ids(o)
            // Request order, each root followed by its descendants; every id once.
            var gone: [String] = [], seen = Set<String>()
            for id in targets {
                _ = try index(s, id)
                for x in [id] + descendants(s, of: id) where seen.insert(x).inserted { gone.append(x) }
            }
            s.nodes.removeAll { seen.contains($0.id) }
            return gone

        case "move":
            guard let id = o["id"]?.string else { throw ModelError.invalid("needs 'id'") }
            let n = s.nodes.remove(at: try index(s, id))
            s.nodes.insert(n, at: try insertionIndex(o, s))
            return [id]

        case "duplicate":
            guard let id = o["id"]?.string, let newId = o["as"]?.string else {
                throw ModelError.invalid("needs id and 'as'")
            }
            if s.nodes.contains(where: { $0.id == newId }) { throw ModelError.invalid("id '\(newId)' already exists") }
            var root = s.nodes[try index(s, id)]
            root.id = newId
            try merge(o, into: &root)
            var copies = [root]
            var rename = [id: newId]
            for d in descendants(s, of: id) {
                var c = s.nodes[try index(s, d)]
                c.id = "\(d)-\(newId)"
                rename[d] = c.id
                copies.append(c)
            }
            for k in copies.indices.dropFirst() { copies[k].parent = copies[k].parent.flatMap { rename[$0] } }
            let at = (try insertionIndex(o, s))
            s.nodes.insert(contentsOf: copies, at: at)
            return copies.map(\.id)

        case "shift":
            let targets = try ids(o)
            guard let by = o["by"]?.double else { throw ModelError.invalid("needs 'by' (seconds)") }
            for id in targets {
                let i = try index(s, id)
                s.nodes[i].start = (s.nodes[i].start ?? 0) + by
                if let e = s.nodes[i].end { s.nodes[i].end = e + by }
            }
            return targets

        case "scene":
            if let d = o["duration"]?.double { s.duration = try duration(d) }
            if let n = o["name"] { s.name = n.string }
            if let f = o["fps"] {
                s.fps = try f.double.map { try SafeNumber.positive($0, "fps", max: SafeNumber.maxFPS) }
            }
            if let z = o["size"] {
                s.size = try z.doubles?.map { try SafeNumber.int($0, "size", in: 1...SafeNumber.maxCanvas) }
            }
            if let b = o["background"] { s.background = b == .null ? nil : try Prop(json: b) }
            if let c = o["camera"] { s.camera = c == .null ? nil : try Prop(json: c) }
            if let f = o["fog"] { s.fog = f == .null ? nil : try Prop(json: f) }
            if let p = o["post"] { s.post = p == .null ? nil : try Prop(json: p) }
            if let a = o["audio"] { s.audio = a == .null ? nil : try a.decoded(as: AudioRef.self) }
            return []

        case "marker":
            // {"op":"marker","name":"lock","t":3.4,"color":"#FC0"} adds or moves; {"op":"marker","name":"lock","remove":true} deletes.
            guard let name = o["name"]?.string, !name.isEmpty else { throw ModelError.invalid("needs 'name'") }
            var list = s.markers ?? []
            list.removeAll { $0.name == name }
            if o["remove"]?.bool != true {
                guard let t = o["t"]?.double else { throw ModelError.invalid("needs 't' (seconds)") }
                list.append(Marker(name: name, t: t, color: o["color"]?.string))
            }
            list.sort { $0.t < $1.t }
            s.markers = list.isEmpty ? nil : list
            return []

        default:
            throw ModelError.invalid("unknown op (add, set, key, remove, move, duplicate, shift, scene, marker)")
        }
    }
}
