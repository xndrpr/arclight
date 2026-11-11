import Foundation
import simd

/// A node resolved at one instant: world transform, inherited opacity, and plain prop values.
public struct EvalNode {
    public let node: Node
    public var world: simd_float4x4
    public var opacity: Double
    /// Node-local time.
    public var t: Double
    public var props: [String: JSONValue]
    /// Rendered through the scene camera (own or inherited `"3d": true`, or a repeater or light).
    public var is3D: Bool = false

    public func num(_ k: String, _ def: Double) -> Double { props[k]?.double ?? def }
    public func str(_ k: String, _ def: String) -> String { props[k]?.string ?? def }
    public func bool(_ k: String, _ def: Bool) -> Bool { props[k]?.bool ?? def }
    public func color(_ k: String) -> RGBA? { RGBA.parse(props[k]) }
}

/// Pure function of (scene, time) → resolved nodes. Deterministic, so preview and export match.
public final class Evaluator {
    public let expr: ExprEngine
    public var theme: [String: JSONValue]

    public init(theme: [String: JSONValue] = Project.defaultTheme, expr: ExprEngine = ExprEngine()) {
        self.theme = theme; self.expr = expr
    }

    // MARK: Props

    /// Replaces `"$token"` strings with theme values (recursively, a few hops deep). `"$token@NN"` is the token's
    /// colour at NN % alpha (0–100), returned as `"#RRGGBBAA"`; a theme key that itself contains "@" wins.
    public func resolve(_ v: JSONValue) -> JSONValue {
        switch v {
        case .string(let s) where s.hasPrefix("$"): return token(s, depth: 0)
        case .array(let a): return .array(a.map(resolve))
        case .object(let o): return .object(o.mapValues(resolve))
        default: return v
        }
    }

    private func token(_ s: String, depth: Int) -> JSONValue {
        var cur: JSONValue = .string(s), hops = 0
        while case .string(let x) = cur, x.hasPrefix("$"), hops < 5 {
            if let next = theme[String(x.dropFirst())] {
                cur = next
            } else if depth < 5, let (base, alpha) = Evaluator.alphaSuffix(x),
                let c = RGBA.parse(token(base, depth: depth + 1))
            {
                cur = .string(RGBA(c.r, c.g, c.b, alpha).hex)
            } else {
                break
            }
            hops += 1
        }
        return cur
    }

    /// `"$accent@25"` → (`"$accent"`, 0.25). Nil unless the text ends in "@" and a whole number 0–100.
    public static func alphaSuffix(_ s: String) -> (base: String, alpha: Double)? {
        guard let at = s.lastIndex(of: "@") else { return nil }
        let digits = s[s.index(after: at)...]
        guard at > s.index(after: s.startIndex), (1...3).contains(digits.count),
            digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), n <= 100
        else { return nil }
        return (String(s[..<at]), Double(n) / 100)
    }

    public func value(_ p: Prop, t: Double, T: Double, i: Int = 0, duration: Double = 0) -> JSONValue {
        switch p {
        case .value(let v): return resolve(v)
        case .expr(let src): return resolve(expr.eval(src, t: t, T: T, i: i, d: duration))
        case .keys(let ks):
            guard let first = ks.first else { return .null }
            if t <= first.t || ks.count == 1 { return resolve(first.v) }
            guard let last = ks.last, t < last.t else { return resolve(ks.last!.v) }
            let j = ks.firstIndex { $0.t > t }!
            let a = ks[j - 1], b = ks[j]
            let u = (t - a.t) / max(b.t - a.t, 1e-9)
            return Evaluator.lerp(resolve(a.v), resolve(b.v), (b.ease ?? .linear).apply(u))
        }
    }

    /// A number setting directly inside a layer's object setting may hold its own keyframes, e.g.
    /// `"pool": {"radius": 200, "intensity": {"k": [[0, 0], [1, 1.2]]}}`: they are interpolated at layer time t.
    /// Only number fields of the schema qualify (`Schema.nestedKeys`), so `{"k": …}` anywhere else is left as it is.
    func nestedKeyframes(
        _ v: JSONValue, type: String, prop: String, t: Double, T: Double, duration: Double
    ) -> JSONValue {
        guard case .object(var o) = v, o.values.contains(where: { $0.object?["k"] != nil }) else { return v }
        for (k, sub) in o {
            guard let ks = Schema.nestedKeys(type: type, prop: prop, key: k, sub) else { continue }
            o[k] = value(.keys(ks), t: t, T: T, duration: duration)
        }
        return .object(o)
    }

    public static func lerp(_ a: JSONValue, _ b: JSONValue, _ u: Double) -> JSONValue {
        switch (a, b) {
        case (.number(let x), .number(let y)): return .number(x + (y - x) * u)
        case (.array(let x), .array(let y)) where x.count == y.count && x.allSatisfy({ $0.double != nil }):
            return .array(zip(x, y).map { lerp($0, $1, u) })
        case (.object(let x), .object(let y)):
            var o = x
            for (k, yv) in y { o[k] = x[k].map { lerp($0, yv, u) } ?? yv }
            return .object(o)
        default:
            if let ca = RGBA.parse(a), let cb = RGBA.parse(b) {
                return RGBA(
                    ca.r + (cb.r - ca.r) * u, ca.g + (cb.g - ca.g) * u, ca.b + (cb.b - ca.b) * u,
                    ca.a + (cb.a - ca.a) * u
                ).json
            }
            return u < 1 ? a : b
        }
    }

    /// Evaluates a scene-level prop (camera, fog, post) at scene time T.
    public func sceneValue(_ p: Prop?, _ scene: Scene, T: Double) -> JSONValue? {
        p.map { value($0, t: T, T: T, duration: scene.duration) }
    }

    public func background(_ scene: Scene, T: Double) -> RGBA {
        RGBA.parse(scene.background.map { value($0, t: T, T: T, duration: scene.duration) } ?? resolve("$bg"))
            ?? RGBA(0, 0, 0)
    }

    // MARK: Scene

    public func evaluate(_ scene: Scene, T: Double) -> [EvalNode] {
        let byId = Dictionary(scene.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var memo: [String: EvalNode?] = [:]

        func eval(_ n: Node, depth: Int) -> EvalNode? {
            if let m = memo[n.id] { return m }
            guard depth < 64 else { return nil }
            let start = n.start ?? 0, end = n.end ?? scene.duration
            guard T >= start, T < end || (end >= scene.duration && T >= end) else {
                memo[n.id] = .some(nil); return nil
            }
            var parentWorld = matrix_identity_float4x4, parentOpacity = 1.0, parent3D = false
            if let pid = n.parent, let p = byId[pid] {
                guard let pe = eval(p, depth: depth + 1) else { memo[n.id] = .some(nil); return nil }
                parentWorld = pe.world; parentOpacity = pe.opacity; parent3D = pe.is3D
            }
            let t = T - start
            var props: [String: JSONValue] = [:]
            for (k, p) in n.props {
                props[k] = value(p, t: t, T: T, duration: scene.duration)
                if case .value = p, let v = props[k] {
                    props[k] = nestedKeyframes(v, type: n.type, prop: k, t: t, T: T, duration: scene.duration)
                }
            }
            if props["visible"]?.bool == false { memo[n.id] = .some(nil); return nil }
            var e = EvalNode(
                node: n, world: parentWorld * Evaluator.localMatrix(props),
                opacity: parentOpacity * (props["opacity"]?.double ?? 1), t: t, props: props)
            e.is3D = props["3d"]?.bool ?? (parent3D || n.type == "repeater" || n.type == "light")
            memo[n.id] = e
            return e
        }
        let markers = Dictionary((scene.markers ?? []).map { ($0.name, $0.t) }, uniquingKeysWith: { a, _ in a })
        expr.markerProvider = { markers[$0] }
        // Live crowd stats for expressions (e.g. a counter showing litFraction("crowd")).
        var stats: [String: (lit: Int, total: Int)] = [:]
        expr.litProvider = { [unowned self] id in
            if let s = stats[id] { return s }
            guard let node = byId[id], node.type == "repeater", let e = eval(node, depth: 1) else { return (0, 0) }
            let items = e.props["items"]?.array?.compactMap(\.object) ?? [[:]]
            let inst = InstanceLayout.build(e, items: items, evaluator: self, T: T, duration: scene.duration)
            let s = (inst.filter { $0.lit >= 0.5 }.count, inst.count)
            stats[id] = s
            return s
        }
        return scene.nodes.compactMap { eval($0, depth: 0) }
    }

    /// T(x,y,z) · Rz · Ry · Rx · S · T(-anchor). Pixel units, origin top-left, y down, degrees.
    static func localMatrix(_ p: [String: JSONValue]) -> simd_float4x4 {
        func f(_ k: String, _ d: Double = 0) -> Float { Float(p[k]?.double ?? d) }
        var sx: Float = 1, sy: Float = 1
        if let s = p["scale"] {
            if let d = s.doubles, d.count >= 2 {
                sx = Float(d[0]); sy = Float(d[1])
            } else if let v = s.double {
                sx = Float(v); sy = sx
            }
        }
        let anchor = p["anchor"]?.doubles ?? [0, 0]
        let ax = Float(anchor.first ?? 0), ay = Float(anchor.count > 1 ? anchor[1] : 0)
        return M.translate(f("x"), f("y"), f("z"))
            * M.rotateZ(f("rotation") * .pi / 180)
            * M.rotateY(f("rotationY") * .pi / 180)
            * M.rotateX(f("rotationX") * .pi / 180)
            * M.scale(sx, sy, 1)
            * M.translate(-ax, -ay, 0)
    }
}
