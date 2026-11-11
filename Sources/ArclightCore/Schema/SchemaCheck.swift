import Foundation

extension Schema {
    /// Problems with one node's props: unknown names (with suggestions), wrong value kinds, bad choices.
    /// Props starting with "_" are free-form custom data and are never checked.
    public static func check(_ n: Node) -> [String] {
        let known = fields(for: n.type)
        var out: [String] = []
        for (name, prop) in n.props.sorted(by: { $0.key < $1.key }) where !name.hasPrefix("_") {
            guard let f = known.first(where: { $0.name == name }) else {
                out.append(
                    "unknown property '\(name)'" + suggestion(name, known.map(\.name)) + " (custom data: prefix with _)"
                )
                continue
            }
            out += checkProp(prop, f, path: name, layer: true)
        }
        return out
    }

    /// Scene-level fields (camera, fog, post…).
    public static func checkScene(_ s: Scene) -> [String] {
        var out: [String] = []
        for (name, p) in [("camera", s.camera), ("fog", s.fog), ("post", s.post), ("background", s.background)] {
            guard let p, let f = sceneFields.first(where: { $0.name == name }) else { continue }
            out += checkProp(p, f, path: name)
        }
        var names = Set<String>()
        for m in s.markers ?? [] {
            if m.name.isEmpty { out.append("markers: a marker needs a name") }
            if !names.insert(m.name).inserted { out.append("markers: duplicate name '\(m.name)'") }
            if m.t < 0 { out.append("markers.\(m.name): time must be ≥ 0") }
        }
        if let a = s.audio {
            if a.src.isEmpty { out.append("audio.src is empty") }
            if let g = a.gain, g < 0 || g > 4 { out.append("audio.gain must be 0…4") }
        }
        return out
    }

    private static func checkProp(_ p: Prop, _ f: Field, path: String, layer: Bool = false) -> [String] {
        switch p {
        case .expr: return []
        case .value(let v): return checkValue(v, f, path: path, nestedKeys: layer)
        case .keys(let ks):
            if !f.animatable { return ["\(path) can't be animated — set a plain value"] }
            return ks.flatMap { checkValue($0.v, f, path: "\(path)@\(Format.number($0.t))s") }
        }
    }

    private static func checkValue(_ v: JSONValue, _ f: Field, path: String, nestedKeys: Bool = false) -> [String] {
        // Theme tokens are accepted anywhere a scalar is expected.
        if case .string(let s) = v, s.hasPrefix("$") { return [] }
        if f.canDisable, v == .bool(false) { return [] }
        func bad(_ expected: String) -> [String] { ["\(path) should be \(expected), got \(v.compactDescription)"] }
        switch f.kind {
        case .number(let lo, let hi, _, _):
            guard let d = v.numberValue else { return bad("a number") }
            if let lo, d < lo - 1e-9 { return ["\(path) must be ≥ \(Format.number(lo)) (got \(Format.number(d)))"] }
            if let hi, d > hi + 1e-9 { return ["\(path) must be ≤ \(Format.number(hi)) (got \(Format.number(d)))"] }
            return []
        case .integer(let lo, let hi):
            guard let d = v.numberValue else { return bad("a whole number") }
            if let lo, d < Double(lo) { return ["\(path) must be ≥ \(lo)"] }
            if let hi, d > Double(hi) { return ["\(path) must be ≤ \(hi)"] }
            return []
        case .bool:
            if case .bool = v { return [] }
            return bad("true or false")
        case .color:
            return RGBA.parse(v) != nil ? [] : bad("a colour (\"#RRGGBB\", \"#RRGGBBAA\", a name, $token or $token@NN)")
        case .paint:
            if RGBA.parse(v) != nil { return [] }
            if let o = v.object, o["stops"] != nil, o["linear"] != nil || o["radial"] != nil { return [] }
            return bad("a colour or a gradient {linear|radial, stops}")
        case .string, .font, .asset, .symbol:
            if case .string = v { return [] }
            return bad("text")
        case .choice(let opts):
            guard let s = v.string, case .string = v else { return bad("one of " + opts.joined(separator: ", ")) }
            return opts.contains(s)
                ? []
                : ["\(path) must be one of " + opts.joined(separator: ", ") + " (got \"\(s)\")" + suggestion(s, opts)]
        case .vector(let labels, _):
            guard let a = v.array, a.count == labels.count, a.allSatisfy({ $0.numberValue != nil }) else {
                return bad("[" + labels.joined(separator: ", ") + "]")
            }
            return []
        case .numberOrVector(let labels):
            if v.numberValue != nil { return [] }
            if let a = v.array, a.count == labels.count, a.allSatisfy({ $0.numberValue != nil }) { return [] }
            return bad("a number or [" + labels.joined(separator: ", ") + "]")
        case .numberOrObject(let o):
            if v.numberValue != nil { return [] }
            return checkObject(v, o, path: path, nestedKeys: nestedKeys)
        case .object(let o):
            return checkObject(v, o, path: path, nestedKeys: nestedKeys)
        case .list(let o):
            guard let a = v.array else { return bad("a list of {\(o.name)}") }
            return a.enumerated().flatMap { checkObject($1, o, path: "\(path)[\($0)]") }
        case .easing:
            return (try? Easing(json: v)) != nil
                ? [] : bad("an easing (\(Easing.names.prefix(6).joined(separator: ", "))… or [x1,y1,x2,y2])")
        case .json:
            return []
        }
    }

    private static func checkObject(
        _ v: JSONValue, _ o: ObjectSchema, path: String, nestedKeys: Bool = false
    ) -> [String] {
        guard let obj = v.object else {
            return ["\(path) should be an object {\(o.fields.map(\.name).joined(separator: ", "))}"]
        }
        var out: [String] = []
        for (k, sub) in obj.sorted(by: { $0.key < $1.key }) where !k.hasPrefix("_") {
            guard let f = o.field(k) else {
                out.append("\(path).\(k) is not a \(o.name) setting" + suggestion(k, o.fields.map(\.name)))
                continue
            }
            // Nested values may themselves be expressions inside per-instance objects.
            if let p = try? Prop(json: sub), case .expr = p { continue }
            // A number setting directly inside a layer's object setting may hold its own keyframes
            // (`"pool": {"intensity": {"k": [...]}}`); the evaluator interpolates them (see `nestedKeyframes`).
            if nestedKeys, f.kind.isNumeric, case .keys(let ks)? = try? Prop(json: sub) {
                if !f.animatable { out.append("\(path).\(k) can't be animated — set a plain value"); continue }
                out += ks.flatMap { checkValue($0.v, f, path: "\(path).\(k)@\(Format.number($0.t))s") }
                continue
            }
            out += checkValue(sub, f, path: "\(path).\(k)")
        }
        return out
    }

    /// " — did you mean 'color'?" for near misses.
    static func suggestion(_ s: String, _ options: [String]) -> String {
        let l = s.lowercased()
        let best = options.map { ($0, levenshtein(l, $0.lowercased())) }.min { $0.1 < $1.1 }
        guard let (name, d) = best, d <= max(2, s.count / 3) else { return "" }
        return " — did you mean '\(name)'?"
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}

extension JSONValue {
    /// Strict number (no string/bool coercion).
    var numberValue: Double? { if case .number(let d) = self { return d }; return nil }

    var compactDescription: String {
        let s = (try? String(data: JSONFormat.compact().encode(self), encoding: .utf8)) ?? "?"
        return s.count > 40 ? String(s.prefix(37)) + "…" : s
    }
}
