import Foundation

/// A/B variants of a thumbnail: copies of one artboard, each changing one thing, laid out in a row to the right
/// and named B, C, D… — ready to export as a set for YouTube's Test & Compare (up to 3 thumbnails).
public enum PreviewVariants {
    /// What an automatic variant changes.
    public enum Axis: String, CaseIterable, Sendable {
        /// Accent-coloured layers get another accent.
        case color
        /// Image layers zoom in (tighter crop on faces and products).
        case zoom
        /// The artboard background changes colour.
        case background
    }

    /// Accent / background alternatives that stay readable with white or black text.
    static let accents = ["#FF3B30", "#2DD4FF", "#7CFF4F", "#FFD60A", "#BF5AF2"]
    static let backgrounds = ["#0B1F3A", "#2A0B0B", "#0B2A16", "#1B1B1B", "#3A2A0B"]

    /// Spec of one variant: a name and the ops (layer or page ops) that make it different. Ops run on the copy.
    public struct Spec: Sendable {
        public var name: String?
        public var ops: [JSONValue]
        public init(name: String? = nil, ops: [JSONValue]) { self.name = name; self.ops = ops }
    }

    /// Adds variants of `base`. Returns the page and the new artboard ids.
    public static func make(_ specs: [Spec], of base: String, in preview: Preview) throws -> (Preview, [String]) {
        var p = preview
        let a = p.artboards[try p.index(of: base)]
        var ids: [String] = []
        let used = Set(p.artboards.compactMap(\.name))
        var letters = (66...90).compactMap { UnicodeScalar($0).map { String(Character($0)) } }.filter { !used.contains($0) }.makeIterator()
        for spec in specs {
            let name = spec.name ?? letters.next() ?? "Variant"
            let id = p.uniqueArtboardId(PreviewVariants.slug(name))
            let r = try PreviewOps.apply(
                [["op": "artboard_duplicate", "id": .string(a.id), "as": .string(id), "name": .string(name)]], to: p)
            p = r.preview
            if !spec.ops.isEmpty { p = try PreviewOps.apply(spec.ops, to: p, artboard: id).preview }
            ids.append(id)
        }
        return (p, ids)
    }

    /// Automatic variant specs: `count` copies, each changing only `axis` (so the test says what worked).
    public static func auto(_ axis: Axis, count: Int, of a: Artboard) -> [Spec] {
        (0..<max(1, min(count, 5))).map { i in
            switch axis {
            case .color:
                let c = JSONValue.string(accents[i % accents.count])
                let ops: [JSONValue] = a.nodes.compactMap { n in
                    var o: [String: JSONValue] = ["op": "set", "id": .string(n.id)]
                    for k in ["color", "fill", "stroke"] where usesAccent(n.props[k]) { o[k] = c }
                    return o.count > 2 ? .object(o) : nil
                }
                return Spec(ops: ops)
            case .zoom:
                let k = 1.15 + Double(i) * 0.15
                let ops: [JSONValue] = a.nodes.filter { $0.type == "image" }.map { n in
                    var scale = 1.0
                    if case .value(let v)? = n.props["scale"], let d = v.double { scale = d }
                    return ["op": "set", "id": .string(n.id), "scale": .number((scale * k * 100).rounded() / 100)]
                }
                return Spec(ops: ops)
            case .background:
                return Spec(ops: [
                    ["op": "artboard_set", "id": "__self__", "background": .string(backgrounds[i % backgrounds.count])]
                ])
            }
        }
    }

    /// An artboard id from a display name: ASCII letters, digits and dashes ("B · Дверь" → "b"); "variant" if none.
    static func slug(_ name: String) -> String {
        let words = name.lowercased().components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted)
            .filter { !$0.isEmpty }
        let s = words.joined(separator: "-")
        return s.isEmpty ? "variant" : String(s.prefix(32))
    }

    static func usesAccent(_ p: Prop?) -> Bool {
        guard case .value(let v)? = p, let s = v.string else { return false }
        return s.hasPrefix("$accent")
    }

    /// Resolves the `__self__` placeholder in page ops to each variant's own id (auto background variants).
    public static func makeAuto(_ axis: Axis, count: Int, of base: String, in preview: Preview) throws -> (Preview, [String]) {
        let a = preview.artboards[try preview.index(of: base)]
        let specs = auto(axis, count: count, of: a)
        var p = preview
        var ids: [String] = []
        for spec in specs {
            let (np, new) = try make([Spec(name: spec.name, ops: [])], of: base, in: p)
            p = np
            let id = new[0]
            let ops = spec.ops.map { op -> JSONValue in
                guard var o = op.object, o["id"]?.string == "__self__" else { return op }
                o["id"] = .string(id)
                return .object(o)
            }
            if !ops.isEmpty { p = try PreviewOps.apply(ops, to: p, artboard: id).preview }
            ids.append(id)
        }
        return (p, ids)
    }
}
