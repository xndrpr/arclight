import ArclightCore
import Foundation

/// Pure timeline edits (no UI): trimming a layer's start, keyframe selection edits, marker names, loop playback.
/// Everything here takes a scene and returns a new one so it can be unit-tested and applied inside a gesture.

/// One keyframe: layer, prop and its node-local time (exactly as stored, so lookups are exact).
struct KeyRef: Hashable {
    var node: String
    var prop: String
    var t: Double
}

enum TimelineEdit {
    /// Moves a layer's in point to `newStart` (scene seconds) without moving its content: keyframes and the
    /// reveal delay shift by −Δ so everything stays at the same scene time. Keys before the new start are kept
    /// (hidden), so trimming back restores them. Returns whether the layer uses expressions (those use `t`
    /// relative to the start and can't be shifted).
    static func trimStart(_ s: Scene, id: String, to newStart: Double) -> (scene: Scene, usesExpressions: Bool) {
        var s = s
        guard let i = s.nodes.firstIndex(where: { $0.id == id }) else { return (s, false) }
        let old = s.nodes[i].start ?? 0
        let d = newStart - old
        s.nodes[i].start = abs(newStart) < 1e-9 ? nil : newStart
        var expr = false
        for (k, p) in s.nodes[i].props {
            switch p {
            case .keys(var ks):
                for j in ks.indices { ks[j].t = round6(ks[j].t - d) }
                s.nodes[i].props[k] = .keys(ks)
            case .expr: expr = true
            case .value(let v):
                if k == "reveal", case .object(var o) = v {
                    let delay = round6((o["delay"]?.double ?? 0) - d)
                    o["delay"] = abs(delay) < 1e-9 ? nil : .number(delay)
                    s.nodes[i].props[k] = .value(.object(o))
                }
            }
        }
        return (s, expr)
    }

    static func round6(_ x: Double) -> Double { (x * 1e6).rounded() / 1e6 }
}

// MARK: Keyframe selection edits

enum KeyEdit {
    /// Keys of a layer (all props, or one) at a scene time (within 1 ms), as shown by one diamond.
    static func refs(_ s: Scene, node id: String, prop: String?, at sceneTime: Double) -> Set<KeyRef> {
        refs(s, node: id, prop: prop, in: (sceneTime - 1e-3)...(sceneTime + 1e-3))
    }

    /// Keys of a layer (all props, or one) inside a scene-time range (box select).
    static func refs(_ s: Scene, node id: String, prop: String?, in range: ClosedRange<Double>) -> Set<KeyRef> {
        guard let n = s.node(id) else { return [] }
        let st = n.start ?? 0
        var out = Set<KeyRef>()
        for (k, p) in n.props where prop == nil || k == prop {
            if case .keys(let ks) = p {
                for kf in ks where range.contains(st + kf.t) { out.insert(KeyRef(node: id, prop: k, t: kf.t)) }
            }
        }
        return out
    }

    /// Drops refs that no longer point at a keyframe (after undo, reload, deletes).
    static func existing(_ s: Scene, _ refs: Set<KeyRef>) -> Set<KeyRef> {
        refs.filter { r in
            if case .keys(let ks)? = s.node(r.node)?.props[r.prop] { return ks.contains { $0.t == r.t } }
            return false
        }
    }

    static func sceneTime(_ s: Scene, _ r: KeyRef) -> Double { (s.node(r.node)?.start ?? 0) + r.t }

    /// Moves the keys by `dt` seconds (clamped so none goes before scene time 0). A moved key replaces an
    /// unmoved key it lands on. Returns the new scene and the moved keys' new refs.
    static func move(_ s: Scene, _ refs: Set<KeyRef>, by dt: Double) -> (scene: Scene, refs: Set<KeyRef>) {
        let refs = existing(s, refs)
        guard !refs.isEmpty else { return (s, refs) }
        let minT = refs.map { sceneTime(s, $0) }.min() ?? 0
        let d = max(dt, -minT)
        var s = s
        var out = Set<KeyRef>()
        for (node, prop) in Set(refs.map { [$0.node, $0.prop] }).map({ ($0[0], $0[1]) }) {
            guard let i = s.nodes.firstIndex(where: { $0.id == node }), case .keys(let ks)? = s.nodes[i].props[prop]
            else { continue }
            let mine = Set(refs.filter { $0.node == node && $0.prop == prop }.map(\.t))
            var moved: [Keyframe] = [], kept: [Keyframe] = []
            for k in ks {
                if mine.contains(k.t) {
                    var m = k; m.t = TimelineEdit.round6(k.t + d); moved.append(m)
                } else {
                    kept.append(k)
                }
            }
            kept.removeAll { k in moved.contains { abs($0.t - k.t) < 1e-6 } }
            s.nodes[i].props[prop] = .keys((kept + moved).sorted { $0.t < $1.t })
            for m in moved { out.insert(KeyRef(node: node, prop: prop, t: m.t)) }
        }
        return (s, out)
    }

    /// Removes the keys. A prop left without keys keeps the value of its first removed key as a constant.
    static func delete(_ s: Scene, _ refs: Set<KeyRef>) -> Scene {
        var s = s
        for i in s.nodes.indices {
            let id = s.nodes[i].id
            for (k, p) in s.nodes[i].props {
                guard case .keys(let ks) = p else { continue }
                let mine = Set(refs.filter { $0.node == id && $0.prop == k }.map(\.t))
                guard !mine.isEmpty else { continue }
                let rest = ks.filter { !mine.contains($0.t) }
                if rest.isEmpty {
                    if let v = ks.first(where: { mine.contains($0.t) })?.v { s.nodes[i].props[k] = .value(v) }
                } else {
                    s.nodes[i].props[k] = .keys(rest)
                }
            }
        }
        return s
    }

    /// Sets the easing (curve arriving at each key). `nil` = default (linear).
    static func setEase(_ s: Scene, _ refs: Set<KeyRef>, _ ease: Easing?) -> Scene {
        var s = s
        for r in refs {
            guard let i = s.nodes.firstIndex(where: { $0.id == r.node }),
                case .keys(var ks)? = s.nodes[i].props[r.prop],
                let j = ks.firstIndex(where: { $0.t == r.t })
            else { continue }
            ks[j].ease = ease
            s.nodes[i].props[r.prop] = .keys(ks)
        }
        return s
    }

    /// Shared easing name of the keys, if they all use the same named one.
    static func commonEase(_ s: Scene, _ refs: Set<KeyRef>) -> String? {
        var names = Set<String>()
        for r in refs {
            guard case .keys(let ks)? = s.node(r.node)?.props[r.prop], let k = ks.first(where: { $0.t == r.t }) else {
                continue
            }
            names.insert(k.ease?.json.string ?? "linear")
        }
        return names.count == 1 ? names.first : nil
    }

    /// Copied keys, relative to the earliest one.
    struct Clip: Equatable {
        struct Item: Equatable {
            var node: String; var prop: String; var dt: Double; var v: JSONValue; var ease: Easing?
        }
        var items: [Item]
    }

    static func copy(_ s: Scene, _ refs: Set<KeyRef>) -> Clip? {
        let refs = existing(s, refs)
        guard let t0 = refs.map({ sceneTime(s, $0) }).min() else { return nil }
        var items: [Clip.Item] = []
        for r in refs.sorted(by: { sceneTime(s, $0) < sceneTime(s, $1) }) {
            guard case .keys(let ks)? = s.node(r.node)?.props[r.prop], let k = ks.first(where: { $0.t == r.t }) else {
                continue
            }
            items.append(
                .init(node: r.node, prop: r.prop, dt: TimelineEdit.round6(sceneTime(s, r) - t0), v: k.v, ease: k.ease))
        }
        return Clip(items: items)
    }

    /// Pastes keys with the earliest at scene time `at`, onto the layers they came from — or all onto `target`
    /// when given (same prop names). Constant props become animated; expression props are skipped.
    static func paste(_ s: Scene, _ clip: Clip, at: Double, target: String? = nil) -> (scene: Scene, refs: Set<KeyRef>)
    {
        var s = s
        var out = Set<KeyRef>()
        for it in clip.items {
            let node = target ?? it.node
            guard let i = s.nodes.firstIndex(where: { $0.id == node }) else { continue }
            let t = TimelineEdit.round6(at + it.dt - (s.nodes[i].start ?? 0))
            var ks: [Keyframe]
            switch s.nodes[i].props[it.prop] {
            case .keys(let k)?: ks = k
            case .expr?: continue
            default: ks = []
            }
            ks.removeAll { abs($0.t - t) < 1e-6 }
            ks.append(Keyframe(t: t, v: it.v, ease: it.ease))
            s.nodes[i].props[it.prop] = .keys(ks.sorted { $0.t < $1.t })
            out.insert(KeyRef(node: node, prop: it.prop, t: t))
        }
        return (s, out)
    }
}

// MARK: Markers

enum MarkerEdit {
    /// Colour names offered in the marker menu (same palette as layer labels).
    static let colors: [(name: String, hex: String)] = [
        ("Red", "#EE5454"), ("Orange", "#F5943D"), ("Yellow", "#EDD14D"), ("Green", "#5CCC75"),
        ("Blue", "#5C99FA"), ("Purple", "#AD7AF5"), ("White", "#F2F2F2"),
    ]

    /// "marker-N" with the smallest unused N (Resolve's M).
    static func nextName(_ s: Scene) -> String {
        let used = Set((s.markers ?? []).map(\.name))
        var k = 1
        while used.contains("marker-\(k)") { k += 1 }
        return "marker-\(k)"
    }

    static func addOp(_ name: String, t: Double, color: String? = nil) -> JSONValue {
        var o: [String: JSONValue] = ["op": "marker", "name": .string(name), "t": .number(t)]
        if let color { o["color"] = .string(color) }
        return .object(o)
    }

    static func removeOp(_ name: String) -> JSONValue { ["op": "marker", "name": .string(name), "remove": true] }

    /// Ops to move / recolour / rename a marker (rename = remove + add, keeping time and colour).
    static func updateOps(_ m: Marker, name: String? = nil, t: Double? = nil, color: String?? = nil) -> [JSONValue] {
        let newName = name ?? m.name
        let add = addOp(newName, t: t ?? m.t, color: color ?? m.color)
        return newName == m.name ? [add] : [removeOp(m.name), add]
    }

    static func expression(_ name: String) -> String { "marker(\"\(name)\")" }
}

// MARK: Loop playback

enum PlaybackLoop {
    /// Advances the playhead by `dt` (negative = backwards). The range is the work area when set, else the
    /// whole scene. With `loop` the playhead wraps inside the range; without it, playback stops at the range end
    /// (`stop`). Starting before the range plays into it; starting past its end jumps back to its start.
    static func advance(
        _ t: Double, by dt: Double, duration: Double, loop: Bool, range: ClosedRange<Double>?
    ) -> (t: Double, stop: Bool) {
        let r = range.flatMap { $0.upperBound - $0.lowerBound > 1e-6 ? $0 : nil } ?? 0...max(duration, 1e-6)
        let lo = r.lowerBound, hi = r.upperBound, len = hi - lo
        let n = t + dt
        if dt >= 0, n >= hi {
            // Already at (or past) the end when playback starts: start over from the range start.
            if t >= hi - 1e-9 { return (lo, false) }
            guard loop else { return (hi, true) }
            return (lo + (n - hi).truncatingRemainder(dividingBy: len), false)
        }
        if dt < 0, n < lo {
            if t <= lo + 1e-9 { return (hi, false) }
            guard loop else { return (lo, true) }
            return (hi - (lo - n).truncatingRemainder(dividingBy: len), false)
        }
        return (n, false)
    }
}
