import ArclightCore
import Foundation

// Pure helpers for editing values nested inside props (e.g. `pool.radius`, `reveal.from.y`, `items.0.symbol`).
// Path components address object keys; a numeric component addresses an array index.

extension JSONValue {
    /// The value at `path` (the value itself for an empty path), or nil when absent.
    func value(at path: [String]) -> JSONValue? {
        guard let head = path.first else { return self }
        let rest = Array(path.dropFirst())
        switch self {
        case .object(let o): return o[head]?.value(at: rest)
        case .array(let a):
            guard let i = Int(head), a.indices.contains(i) else { return nil }
            return a[i].value(at: rest)
        default: return nil
        }
    }

    /// A copy with `path` set to `v` (nil removes it). Missing or non-object parents (e.g. a `false`
    /// "off" switch or a number shorthand) become objects; an empty path replaces the whole value.
    func setting(path: [String], to v: JSONValue?) -> JSONValue {
        guard let head = path.first else { return v ?? .null }
        let rest = Array(path.dropFirst())
        if case .array(var a) = self, let i = Int(head) {
            guard i >= 0 else { return self }
            if i < a.count {
                if rest.isEmpty, v == nil { a.remove(at: i) } else { a[i] = a[i].setting(path: rest, to: v) }
            } else if let v {
                while a.count < i { a.append(.null) }
                a.append(JSONValue.null.setting(path: rest, to: v))
            }
            return .array(a)
        }
        var o = object ?? [:]
        if rest.isEmpty {
            o[head] = v
        } else if let child = o[head] {
            o[head] = child.setting(path: rest, to: v)
        } else if let v {
            o[head] = JSONValue.object([:]).setting(path: rest, to: v)
        }
        return .object(o)
    }
}

extension Prop {
    /// The stored value at node-local time `t` without resolving theme tokens: constants as-is, keyframes
    /// interpolated (an exact key wins). Expressions return nil (they need the evaluator).
    func rawValue(at t: Double) -> JSONValue? {
        switch self {
        case .value(let v): return v
        case .expr: return nil
        case .keys(let ks):
            guard let first = ks.first else { return nil }
            if let k = ks.first(where: { abs($0.t - t) < 1e-4 }) { return k.v }
            if t <= first.t || ks.count == 1 { return first.v }
            guard let last = ks.last, t < last.t else { return ks.last!.v }
            let j = ks.firstIndex { $0.t > t }!
            let a = ks[j - 1], b = ks[j]
            let u = (t - a.t) / max(b.t - a.t, 1e-9)
            return Evaluator.lerp(a.v, b.v, (b.ease ?? .linear).apply(u))
        }
    }

    /// The keyframe at `t` (within half a frame), if any.
    func key(at t: Double, fps: Double) -> Keyframe? {
        guard case .keys(let ks) = self else { return nil }
        return ks.first { abs($0.t - t) < 0.5 / fps }
    }

    /// Sets `path` inside this prop to `v` at node-local time `t`.
    /// - Constants are edited in place. Expressions are replaced by the value.
    /// - Keyframed props get a key at `t` (an existing key there is edited; otherwise a new key holding the
    ///   interpolated value is inserted), like auto-key.
    /// - Removing (`v == nil`) a nested field from a keyframed prop removes it from every key.
    func setting(path: [String], to v: JSONValue?, at t: Double) -> Prop? {
        let ft = (t * 1000).rounded() / 1000
        switch self {
        case .keys(var ks):
            if path.isEmpty, v == nil { return nil }
            if v == nil {
                for k in ks.indices { ks[k].v = ks[k].v.setting(path: path, to: nil) }
                return .keys(ks)
            }
            if let k = ks.firstIndex(where: { abs($0.t - ft) < 1e-4 }) {
                ks[k].v = ks[k].v.setting(path: path, to: v)
            } else {
                let base = rawValue(at: ft) ?? .null
                ks.append(Keyframe(t: ft, v: base.setting(path: path, to: v), ease: ks.last?.ease))
                ks.sort { $0.t < $1.t }
            }
            return .keys(ks)
        case .value(let cur):
            if path.isEmpty { return v.map { .value($0) } }
            return .value(cur.setting(path: path, to: v))
        case .expr:
            if path.isEmpty { return v.map { .value($0) } }
            return .value(JSONValue.object([:]).setting(path: path, to: v))
        }
    }

    /// Adds a key at `t` holding `current`, or removes the key there (the last key removed leaves a constant).
    func togglingKey(at t: Double, current: JSONValue) -> Prop {
        let ft = (t * 1000).rounded() / 1000
        switch self {
        case .keys(var ks):
            if let k = ks.firstIndex(where: { abs($0.t - ft) < 1e-4 }) {
                ks.remove(at: k)
                return ks.isEmpty ? .value(current) : .keys(ks)
            }
            ks.append(Keyframe(t: ft, v: current, ease: ks.last?.ease)); ks.sort { $0.t < $1.t }
            return .keys(ks)
        default:
            return .keys([Keyframe(t: ft, v: current)])
        }
    }

    /// Sets the easing of the key at `t` (arriving at it).
    func settingEase(_ e: Easing, at t: Double, fps: Double) -> Prop {
        guard case .keys(var ks) = self, let k = ks.firstIndex(where: { abs($0.t - t) < 0.5 / fps }) else {
            return self
        }
        ks[k].ease = e
        return .keys(ks)
    }

    /// Merges keyframes: existing keys inside the new keys' time span are replaced.
    func mergingKeys(_ new: [Keyframe]) -> Prop {
        guard let lo = new.map(\.t).min(), let hi = new.map(\.t).max() else { return self }
        var ks: [Keyframe]
        switch self {
        case .keys(let old): ks = old.filter { $0.t < lo - 1e-4 || $0.t > hi + 1e-4 }
        default: ks = []
        }
        ks += new
        return .keys(ks.sorted { $0.t < $1.t })
    }
}

/// A nested value that is itself an expression (`{"expr": "…"}`), as used inside `instance`.
extension JSONValue {
    var nestedExpr: String? {
        guard let o = object, o.count == 1, let s = o["expr"]?.string else { return nil }
        return s
    }
}
