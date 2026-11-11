import ArclightCore
import Foundation

/// One-click animations for the "Animate" menu. Each preset is a pure function of the layer that returns the
/// props to write: keyframes (merged with existing ones in the preset's time span) or a `reveal` object.
struct AnimationPreset: Identifiable {
    enum Group: String, CaseIterable { case entrance = "In", exit = "Out", emphasis = "Emphasis" }

    let id: String
    let title: String
    let group: Group
    /// Length of the animation (s).
    let duration: Double
    let applies: (Node) -> Bool
    /// `at`: node-local time the animation starts.
    let make: (_ node: Node, _ at: Double, _ fps: Double) -> [String: Prop]

    func callAsFunction(_ node: Node, at: Double, fps: Double) -> [String: Prop] { make(node, at, fps) }
}

enum AnimationPresets {
    static let slide = 60.0

    static let all: [AnimationPreset] = [
        // In
        AnimationPreset(id: "fadeIn", title: "Fade", group: .entrance, duration: 0.5, applies: { _ in true }) {
            n, at, fps in
            let a = snap(at, fps)
            return [
                "opacity": keys(n, "opacity", [(a, 0, nil), (a + 0.5, base(n, "opacity", 1, at: a + 0.5), "outCubic")])
            ]
        },
        AnimationPreset(id: "slideUp", title: "Slide up", group: .entrance, duration: 0.6, applies: { _ in true }) {
            n, at, fps in
            let a = snap(at, fps), y = num(n, "y", at: a + 0.6)
            return [
                "y": keys(n, "y", [(a, .number(y + slide), nil), (a + 0.6, .number(y), "outExpo")]),
                "opacity": keys(
                    n, "opacity", [(a, 0, nil), (a + 0.4, base(n, "opacity", 1, at: a + 0.6), "outCubic")]),
            ]
        },
        AnimationPreset(id: "slideLeft", title: "Slide left", group: .entrance, duration: 0.6, applies: { _ in true }) {
            n, at, fps in
            let a = snap(at, fps), x = num(n, "x", at: a + 0.6)
            return [
                "x": keys(n, "x", [(a, .number(x + slide * 1.5), nil), (a + 0.6, .number(x), "outExpo")]),
                "opacity": keys(
                    n, "opacity", [(a, 0, nil), (a + 0.4, base(n, "opacity", 1, at: a + 0.6), "outCubic")]),
            ]
        },
        AnimationPreset(id: "scalePop", title: "Scale pop", group: .entrance, duration: 0.5, applies: { _ in true }) {
            n, at, fps in
            let a = snap(at, fps)
            let s = base(n, "scale", 1, at: a + 0.5)
            return [
                "scale": keys(n, "scale", [(a, scaled(s, 0), nil), (a + 0.5, s, "outBack")]),
                "opacity": keys(
                    n, "opacity", [(a, 0, nil), (a + 0.2, base(n, "opacity", 1, at: a + 0.5), "outCubic")]),
            ]
        },
        AnimationPreset(
            id: "maskReveal", title: "Mask reveal", group: .entrance, duration: 0.7, applies: { $0.type == "text" }
        ) { n, at, fps in
            let size = num(n, "size", at: at, default: 100)
            return [
                "reveal": .value([
                    "by": "line", "stagger": 0.08, "duration": 0.7, "delay": .number(snap(at, fps)), "ease": "outExpo",
                    "mask": true,
                    "from": ["opacity": 1, "y": .number((size * 1.1).rounded())],
                ])
            ]
        },
        AnimationPreset(
            id: "typewriter", title: "Typewriter", group: .entrance, duration: 0.8, applies: { $0.type == "text" }
        ) { n, at, fps in
            let chars = max(1, (n.props["text"].flatMap { $0.rawValue(at: at)?.string } ?? "Text").count)
            // Whole text types on in about 0.8 s, but never faster than 25 ms per character.
            let stagger = max(0.025, min(0.08, 0.8 / Double(chars)))
            return [
                "reveal": .value([
                    "by": "char", "stagger": .number((stagger * 1000).rounded() / 1000), "duration": 0.02,
                    "delay": .number(snap(at, fps)),
                    "ease": "linear", "mask": false, "from": ["opacity": 0, "y": 0],
                ])
            ]
        },
        AnimationPreset(
            id: "countUp", title: "Count up", group: .entrance, duration: 0.8, applies: { countTarget($0) != nil }
        ) { n, at, fps in
            guard let (text, target, decimals) = countTarget(n) else { return [:] }
            let a = snap(at, fps)
            var out: [String: Prop] = ["value": keys(n, "value", [(a, 0, nil), (a + 0.8, .number(target), "outExpo")])]
            if text != (n.props["text"]?.rawValue(at: a)?.string ?? "") { out["text"] = .value(.string(text)) }
            if decimals > 0, n.props["decimals"] == nil { out["decimals"] = .value(.number(Double(decimals))) }
            if n.props["tabular"] == nil { out["tabular"] = .value(true) }
            return out
        },
        AnimationPreset(
            id: "drawOn", title: "Draw on", group: .entrance, duration: 0.8,
            applies: { $0.type == "shape" && $0.props["shape"]?.rawValue(at: 0)?.string == "line" }
        ) { n, at, fps in
            let a = snap(at, fps)
            return ["trim": keys(n, "trim", [(a, [0, 0], nil), (a + 0.8, [0, 1], "inOutCubic")])]
        },
        // Out
        AnimationPreset(id: "fadeOut", title: "Fade", group: .exit, duration: 0.4, applies: { _ in true }) {
            n, at, fps in
            let a = snap(at, fps)
            return ["opacity": keys(n, "opacity", [(a, base(n, "opacity", 1, at: a), nil), (a + 0.4, 0, "inCubic")])]
        },
        AnimationPreset(id: "slideDown", title: "Slide down", group: .exit, duration: 0.5, applies: { _ in true }) {
            n, at, fps in
            let a = snap(at, fps), y = num(n, "y", at: a)
            return [
                "y": keys(n, "y", [(a, .number(y), nil), (a + 0.5, .number(y + slide), "inCubic")]),
                "opacity": keys(n, "opacity", [(a + 0.1, base(n, "opacity", 1, at: a), nil), (a + 0.5, 0, "inCubic")]),
            ]
        },
        AnimationPreset(id: "scaleOut", title: "Scale out", group: .exit, duration: 0.4, applies: { _ in true }) {
            n, at, fps in
            let a = snap(at, fps), s = base(n, "scale", 1, at: a)
            return [
                "scale": keys(n, "scale", [(a, s, nil), (a + 0.4, scaled(s, 0), "inBack")]),
                "opacity": keys(n, "opacity", [(a + 0.2, base(n, "opacity", 1, at: a), nil), (a + 0.4, 0, "inCubic")]),
            ]
        },
        // Emphasis
        AnimationPreset(id: "pulse", title: "Pulse", group: .emphasis, duration: 0.5, applies: { _ in true }) {
            n, at, fps in
            let a = snap(at, fps), s = base(n, "scale", 1, at: a)
            return [
                "scale": keys(
                    n, "scale", [(a, s, nil), (a + 0.2, scaled(s, 1.12), "outCubic"), (a + 0.5, s, "inOutCubic")])
            ]
        },
        AnimationPreset(id: "shake", title: "Shake", group: .emphasis, duration: 0.4, applies: { _ in true }) {
            n, at, fps in
            let a = snap(at, fps), x = num(n, "x", at: a)
            let offsets: [Double] = [0, -14, 11, -7, 4, 0]
            let ks = offsets.enumerated().map { (k, o) in
                (a + Double(k) * 0.08, JSONValue.number(x + o), k == 0 ? nil : "inOutSine")
            }
            return ["x": keys(n, "x", ks)]
        },
    ]

    static func preset(_ id: String) -> AnimationPreset? { all.first { $0.id == id } }

    /// Node-local start time for a preset: entrances and emphasis start at the playhead (or the in point if the
    /// playhead is before it); exits end at the layer's out point when it has one.
    static func startTime(_ p: AnimationPreset, node: Node, sceneTime: Double, sceneDuration: Double) -> Double {
        let start = node.start ?? 0
        let local = max(0, sceneTime - start)
        if p.group == .exit, let end = node.end { return max(0, end - start - p.duration) }
        if p.group == .exit, sceneTime >= sceneDuration - 0.001 { return max(0, sceneDuration - start - p.duration) }
        return local
    }

    // MARK: Helpers

    static func snap(_ t: Double, _ fps: Double) -> Double { fps > 0 ? (t * fps).rounded() / fps : t }

    /// The layer's stored value of a prop at `t` (constants and keyframes), else `def`.
    static func base(_ n: Node, _ prop: String, _ def: JSONValue, at t: Double) -> JSONValue {
        guard let v = n.props[prop]?.rawValue(at: t), v != .null else { return def }
        return v
    }

    static func num(_ n: Node, _ prop: String, at t: Double, default d: Double = 0) -> Double {
        base(n, prop, .number(d), at: t).double ?? d
    }

    /// Scales a number or vector scale by `f`.
    static func scaled(_ s: JSONValue, _ f: Double) -> JSONValue {
        if let a = s.doubles, a.count >= 2 { return .array(a.map { .number(($0 * f * 1000).rounded() / 1000) }) }
        return .number(((s.double ?? 1) * f * 1000).rounded() / 1000)
    }

    /// Keyframes merged into the layer's existing prop.
    static func keys(_ n: Node, _ prop: String, _ ks: [(Double, JSONValue, String?)]) -> Prop {
        let new = ks.map { Keyframe(t: ($0.0 * 1000).rounded() / 1000, v: $0.1, ease: $0.2.map(Easing.init)) }
        return (n.props[prop] ?? .value(.null)).mergingKeys(new)
    }

    /// For Count up: (text with {v}, target number, decimals). Uses `value` when the text already has {v},
    /// otherwise turns the first number in the text into {v}.
    static func countTarget(_ n: Node) -> (String, Double, Int)? {
        guard n.type == "text", let text = n.props["text"]?.rawValue(at: 0)?.string else { return nil }
        if text.contains("{v}") {
            let target: Double
            if case .keys(let ks)? = n.props["value"], let last = ks.last?.v.double {
                target = last
            } else {
                target = n.props["value"]?.rawValue(at: 0)?.double ?? 100
            }
            let dec = Int(n.props["decimals"]?.rawValue(at: 0)?.double ?? 0)
            return (text, target == 0 ? 100 : target, dec)
        }
        guard let r = text.range(of: #"\d+([.,]\d+)?"#, options: .regularExpression) else { return nil }
        let token = String(text[r])
        guard let v = Double(token.replacingOccurrences(of: ",", with: ".")) else { return nil }
        let dec =
            token.firstIndex(where: { $0 == "." || $0 == "," }).map { token.distance(from: $0, to: token.endIndex) - 1 }
            ?? 0
        return (text.replacingCharacters(in: r, with: "{v}"), v, dec)
    }
}
