import Foundation

extension Schema {
    /// One line describing a layer, e.g. "“45%” · HelveticaNeue 300" or "Repeater · grid 40×36 · person, knight".
    public static func summary(_ n: Node, childCount: Int = 0) -> String {
        func c(_ k: String) -> JSONValue? { if case .value(let v)? = n.props[k] { return v }; return nil }
        func num(_ k: String) -> String? { c(k)?.numberValue.map(Format.number) }
        let animated = n.props.filter { $0.value.isAnimated }.map(\.key).sorted()
        var s: String
        switch n.type {
        case "text":
            var t = c("text")?.string ?? "…"
            t = t.replacingOccurrences(of: "\n", with: " ")
            if t.count > 28 { t = String(t.prefix(26)) + "…" }
            let font = (c("font")?.string ?? "$display").replacingOccurrences(of: "$", with: "")
            s = "“\(t)” · \(font) \(num("size") ?? "100")"
        case "shape":
            let kind = c("shape")?.string ?? "rect"
            if kind == "line" {
                let to = c("to")?.doubles ?? [200, 0]
                s =
                    "Line \(Format.number((to[0] * to[0] + (to.count > 1 ? to[1] * to[1] : 0)).squareRoot().rounded())) px"
            } else {
                s =
                    (kind == "ellipse" ? "Ellipse " : "Rect ")
                    + "\(num("width") ?? "200")×\(num("height") ?? (kind == "ellipse" ? num("width") ?? "200" : "200"))"
                if c("fill")?.object?["stops"] != nil { s += " · gradient" }
            }
        case "symbol":
            let id = c("symbol")?.string ?? defaultSymbol
            s = "\(id.split(separator: "/").last.map(String.init) ?? id) · \(num("size") ?? "200") px"
        case "image":
            s = (c("src")?.string).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "no file"
        case "group":
            s = "\(childCount) layer\(childCount == 1 ? "" : "s")"
        case "repeater":
            let layout = c("layout")?.string ?? "grid"
            let count =
                layout == "grid"
                ? "\(num("cols") ?? "10")×\(num("rows") ?? "10")"
                : layout == "points" ? "\(c("points")?.array?.count ?? 0) points" : "\(num("count") ?? "100")"
            var names: [String] = []
            for item in c("items")?.array ?? [] {
                let raw: String? =
                    item["symbol"]?.string ?? item["piece"]?.string ?? item["glyph"]?.string ?? item["shape"]?.string
                if let r = raw { names.append(r.split(separator: "/").last.map(String.init) ?? r) }
            }
            s =
                "\(layout) \(count)"
                + (names.isEmpty
                    ? " · dots" : " · " + names.prefix(3).joined(separator: ", ") + (names.count > 3 ? "…" : ""))
            if n.props["pool"] != nil || n.props["cone"] != nil { s += " · lit" }
        case "light":
            s = "pool r=\(c("pool")?["radius"]?.numberValue.map(Format.number) ?? "150")"
        default:
            s = n.type
        }
        if !animated.isEmpty {
            s += " · ◆ " + animated.prefix(2).joined(separator: ", ") + (animated.count > 2 ? "…" : "")
        }
        return s
    }
}
