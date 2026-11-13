import Foundation

/// Batch edits applied atomically to a preview page. Layer ops are the scene ops (`SceneOps`: add, set, key, remove,
/// move, duplicate, scene) run on one artboard: the call's default artboard, or an op's own `"artboard"`.
///
/// Page ops:
/// - `{"op":"artboard_add","id":"b","name":"B","size":[1080,1920],"x":1400,"y":0,"background":"$bg","copy_from":"a"}`
///   (x/y default to the right of the last artboard; `copy_from` copies layers, background and grade)
/// - `{"op":"artboard_set","id":"a","name":"A","size":[1280,720],"x":0,"y":0,"background":"#111","post":{…}}`
/// - `{"op":"artboard_duplicate","id":"a","as":"b","name":"B"}`: a variant, placed to the right
/// - `{"op":"artboard_remove","id":"b"}`
/// - `{"op":"artboard_move","id":"b","index":0}`: order in the page (and in exports)
/// - `{"op":"preview","name":"…","theme":"project" | {"detached":true,"tokens":{…}}}`
public enum PreviewOps {
    public struct Result {
        public var preview: Preview
        public var changed: [String]
        public var summary: String
    }

    static let pageOps: Set<String> = [
        "artboard_add", "artboard_set", "artboard_duplicate", "artboard_remove", "artboard_move", "preview",
    ]

    public static func apply(_ ops: [JSONValue], to preview: Preview, artboard: String? = nil) throws -> Result {
        var p = preview
        var changed: [String] = [], summary: [String] = []
        for (i, op) in ops.enumerated() {
            guard let o = op.object, let kind = o["op"]?.string else { throw ModelError.invalid("op \(i): missing 'op'") }
            do {
                if pageOps.contains(kind) {
                    let ids = try page(kind, o, &p)
                    changed += ids
                    summary.append("\(kind) \(ids.joined(separator: ","))")
                } else {
                    let target = o["artboard"]?.string ?? artboard ?? p.artboards.first?.id
                    guard let target else { throw ModelError.invalid("the preview has no artboard yet (artboard_add)") }
                    let k = try p.index(of: target)
                    var op = o
                    op["artboard"] = nil
                    let r = try SceneOps.apply([.object(op)], to: p.artboards[k].asScene(preview: p.id))
                    p.artboards[k].update(from: r.scene)
                    changed += r.changed.map { "\(target)/\($0)" }
                    summary.append("\(target): \(r.summary)")
                }
            } catch {
                throw ModelError.invalid("op \(i) (\(kind)): \(error)")
            }
        }
        var seen = Set<String>()
        return Result(
            preview: p, changed: changed.filter { seen.insert($0).inserted }, summary: summary.joined(separator: "; "))
    }

    static func size(_ v: JSONValue) throws -> [Int] {
        guard let d = v.doubles, d.count == 2 else { throw ModelError.invalid("size must be [width, height]") }
        return try d.map { try SafeNumber.int($0, "size", in: 16...SafeNumber.maxCanvas) }
    }

    /// A board position: finite and within ±1,000,000 px.
    static func position(_ d: Double, _ what: String) throws -> Double {
        guard d.isFinite, abs(d) <= 1_000_000 else { throw ModelError.invalid("\(what) must be within ±1000000") }
        return d
    }

    /// Applies artboard fields (name, size, x, y, background, post) from an op or a create call.
    public static func setFields(_ o: [String: JSONValue], on a: inout Artboard) throws {
        if let n = o["name"] { a.name = n.string }
        if let z = o["size"] { a.size = try size(z) }
        if let x = o["x"]?.double { a.x = try position(x, "x") }
        if let y = o["y"]?.double { a.y = try position(y, "y") }
        if let b = o["background"] { a.background = b == .null ? nil : try Prop(json: b) }
        if let g = o["post"] { a.post = g == .null ? nil : try Prop(json: g) }
    }

    static func page(_ kind: String, _ o: [String: JSONValue], _ p: inout Preview) throws -> [String] {
        switch kind {
        case "artboard_add":
            let id = try SafeName.id(o["id"]?.string ?? p.uniqueArtboardId("artboard"), what: "artboard id")
            guard p.artboard(id) == nil else { throw ModelError.invalid("artboard '\(id)' already exists") }
            var a = Artboard(id: id)
            if let from = o["copy_from"]?.string {
                a = p.artboards[try p.index(of: from)]; a.id = id; a.name = nil
            } else {
                a.background = .value("$bg")
            }
            (a.x, a.y) = p.nextArtboardOrigin()
            try setFields(o, on: &a)
            p.artboards.append(a)
            return [id]

        case "artboard_set":
            guard let id = o["id"]?.string else { throw ModelError.invalid("needs 'id'") }
            let i = try p.index(of: id)
            try setFields(o, on: &p.artboards[i])
            return [id]

        case "artboard_duplicate":
            guard let id = o["id"]?.string else { throw ModelError.invalid("needs 'id'") }
            var a = p.artboards[try p.index(of: id)]
            let newId = try SafeName.id(o["as"]?.string ?? p.uniqueArtboardId(id), what: "artboard id")
            guard p.artboard(newId) == nil else { throw ModelError.invalid("artboard '\(newId)' already exists") }
            a.id = newId
            a.name = o["name"]?.string ?? a.name.map { "\($0) copy" }
            (a.x, a.y) = p.nextArtboardOrigin()
            try setFields(o.filter { $0.key != "name" }, on: &a)
            p.artboards.append(a)
            return [newId]

        case "artboard_remove":
            guard let id = o["id"]?.string else { throw ModelError.invalid("needs 'id'") }
            p.artboards.remove(at: try p.index(of: id))
            return [id]

        case "artboard_move":
            guard let id = o["id"]?.string, let at = o["index"]?.double else {
                throw ModelError.invalid("needs 'id' and 'index'")
            }
            let a = p.artboards.remove(at: try p.index(of: id))
            p.artboards.insert(a, at: try SafeNumber.clampedInt(at, "index", to: 0...p.artboards.count))
            return [id]

        case "preview":
            if let n = o["name"] { p.name = n.string }
            if let t = o["theme"] { p.theme = try t.decoded(as: ThemeLink.self) }
            return []

        default:
            throw ModelError.invalid("unknown page op")
        }
    }
}
