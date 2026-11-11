import ArclightCore
import Foundation

/// How a layer type's schema fields are grouped into inspector sections, and which fields matter for the
/// layer's current mode (e.g. a line has no corner radius). Fields not listed in a group land in the last one.
enum InspectorLayout {
    struct Group {
        let title: String
        let names: [String]
    }

    static let groups: [String: [Group]] = [
        "text": [
            Group(
                title: "Text", names: ["text", "font", "size", "color", "align", "tracking", "lineHeight", "uppercase"]),
            Group(title: "Number", names: ["value", "decimals", "tabular", "thousands"]),
            Group(title: "Reveal", names: ["reveal"]),
        ],
        "shape": [
            Group(title: "Shape", names: ["shape", "width", "height", "radius", "to", "cap"]),
            Group(title: "Fill & stroke", names: ["fill", "stroke", "strokeWidth", "trim"]),
        ],
        "image": [Group(title: "Image", names: ["src", "width", "height"])],
        "repeater": [
            Group(
                title: "Layout",
                names: ["layout", "cols", "rows", "spacing", "jitter", "count", "area", "radius", "points", "seed"]),
            Group(title: "Copies", names: ["items", "color", "facing", "rim", "rimColor"]),
            Group(title: "Per copy", names: ["instance"]),
            Group(title: "Floor & light", names: ["ground", "ambient", "pool", "contact", "cone", "shadow", "beam"]),
        ],
        "light": [Group(title: "Light", names: ["pool", "beam"])],
    ]

    /// Sections for a layer type: (title, fields) in schema order within each group.
    static func sections(for type: String) -> [(String, [Field])] {
        let own = Schema.node(type)?.fields ?? []
        guard let gs = groups[type], !gs.isEmpty else {
            return own.isEmpty ? [] : [(Schema.node(type)?.label ?? type, own)]
        }
        var used = Set<String>()
        var out: [(String, [Field])] = gs.map { g in
            let fs = g.names.compactMap { n in own.first { $0.name == n } }
            used.formUnion(fs.map(\.name))
            return (g.title, fs)
        }
        let rest = own.filter { !used.contains($0.name) }
        if !rest.isEmpty { out[out.count - 1].1 += rest }
        return out.filter { !$0.1.isEmpty }
    }

    /// Whether a field applies to the layer as it is set up now. Fields that are set always show.
    static func relevant(_ f: Field, _ n: Node) -> Bool {
        if n.props[f.name] != nil { return true }
        func mode(_ k: String, _ def: String) -> String { n.props[k]?.rawValue(at: 0)?.string ?? def }
        switch n.type {
        case "shape":
            let shape = mode("shape", "rect")
            switch f.name {
            case "to", "trim", "cap": return shape == "line"
            case "width", "height", "fill": return shape != "line"
            case "radius": return shape == "rect"
            default: return true
            }
        case "repeater":
            let layout = mode("layout", "grid")
            switch f.name {
            case "cols", "rows", "spacing", "jitter": return layout == "grid"
            case "count": return layout == "scatter" || layout == "ring"
            case "area": return layout == "scatter"
            case "radius": return layout == "ring"
            case "points": return layout == "points"
            default: return true
            }
        case "text":
            if ["decimals", "tabular", "thousands", "value"].contains(f.name) {
                return (n.props["text"]?.rawValue(at: 0)?.string ?? "").contains("{v}")
            }
            return true
        default:
            return true
        }
    }
}
