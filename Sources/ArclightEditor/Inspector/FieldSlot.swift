import ArclightCore
import SwiftUI

/// One schema field at one place: a root prop of a layer or the scene, plus a path inside it.
/// Reads the stored value at the playhead and writes through `EditorDocument.write` (auto-key aware).
struct Slot {
    let host: PropHost
    let root: String
    let path: [String]
    let field: Field
    /// Stored value at the playhead (tokens kept), nil when absent.
    let stored: JSONValue?
    /// Expression source when the value is an expression.
    let expr: String?
    /// The root prop is keyframed.
    let rootAnimated: Bool
    let keyHere: Bool
    /// Node-local (or scene) playhead time for this host.
    let local: Double
    /// Inside a list (e.g. camera shake): edits apply to every keyframe of a keyframed root, since lists
    /// don't interpolate.
    var allKeys = false
    /// A number setting inside a layer's object setting that holds its own keyframes
    /// (`"pool": {"intensity": {"k": …}}`): `stored` is its value at the playhead, and it is changed only through
    /// the object's "Edit as JSON…", so a typed or dragged number can't replace the keyframes.
    var keyedInside = false

    var isTop: Bool { path.isEmpty }
    var isSet: Bool { stored != nil || expr != nil }
    var id: String { ([root] + path).joined(separator: ".") }
    /// Value to show: stored, else the schema default.
    var shown: JSONValue? { stored ?? field.defaultValue }

    /// Expressions are evaluated per prop by the engine at the top level, and per copy inside `instance`.
    var exprAllowed: Bool {
        guard field.animatable else { return false }
        switch field.kind {
        case .object, .list, .json, .asset, .symbol, .font: return false
        default: break
        }
        return isTop || (root == "instance" && path.count == 1)
    }

    /// Top-level animatable props get ‹ ◆ › controls (objects have them in their header).
    var keyable: Bool { isTop && field.animatable && expr == nil }
}

extension EditorDocument {
    func slot(_ host: PropHost, _ root: String, path: [String] = [], field: Field) -> Slot {
        let p = rootProp(host, root)
        let t = localTime(host)
        var stored: JSONValue?, expr: String?, keyedInside = false
        if path.count == 1, case .node(let id) = host, case .value(let v)? = p, let type = scene.node(id)?.type,
            let sub = v.value(at: path), let ks = Schema.nestedKeys(type: type, prop: root, key: path[0], sub)
        {
            stored = Prop.keys(ks).rawValue(at: t); keyedInside = true
        } else if let p {
            if path.isEmpty {
                if case .expr(let s) = p { expr = s } else { stored = p.rawValue(at: t) }
            } else if let v = p.rawValue(at: t)?.value(at: path) {
                if let e = v.nestedExpr { expr = e } else if v != .null { stored = v }
            }
        }
        return Slot(
            host: host, root: root, path: path, field: field, stored: stored, expr: expr,
            rootAnimated: p?.keyCount ?? 0 > 0, keyHere: p?.key(at: t, fps: fps) != nil, local: t,
            keyedInside: keyedInside)
    }

    func child(_ s: Slot, _ f: Field) -> Slot { child(s, [f.name], f) }

    /// A slot further down the path (e.g. a list row's field: `["0", "symbol"]`).
    func child(_ s: Slot, _ components: [String], _ f: Field) -> Slot {
        var c = slot(s.host, s.root, path: s.path + components, field: f)
        if case .list = s.field.kind { c.allKeys = true } else { c.allKeys = s.allKeys }
        return c
    }

    func write(_ s: Slot, _ v: JSONValue?) {
        var allKeys = s.allKeys
        if case .list = s.field.kind { allKeys = true }
        if allKeys, case .keys(let ks)? = rootProp(s.host, s.root) {
            let next = ks.map { k -> Keyframe in
                var k = k; k.v = k.v.setting(path: s.path, to: v); return k
            }
            setRootProp(s.host, s.root, .keys(next))
        } else {
            write(s.host, s.root, path: s.path, v)
        }
    }

    /// Switches a slot to an expression (or back to a plain value when `src` is nil).
    func setExpr(_ s: Slot, _ src: String?) {
        if s.isTop {
            if let src {
                setRootProp(s.host, s.root, .expr(src))
            } else {
                setRootProp(s.host, s.root, .value(evaluated(s) ?? s.field.defaultValue ?? 0))
            }
        } else {
            write(s, src.map { ["expr": .string($0)] } ?? (s.field.defaultValue ?? 0))
        }
    }

    /// Value of a slot at the playhead as the renderer sees it (tokens resolved, expressions run).
    func evaluated(_ s: Slot) -> JSONValue? {
        if let e = s.expr {
            return renderer.evaluator.value(.expr(e), t: s.local, T: time, duration: scene.duration)
        }
        return s.stored.map { renderer.evaluator.resolve($0) }
    }

    /// Begins/updates/ends a drag on a slot (one undo step per drag).
    func scrub(_ s: Slot, _ v: Double, _ phase: ScrubLabel.Phase) {
        guard !s.keyedInside else { return }  // one number would replace its keyframes
        switch phase {
        case .began: beginGesture()
        case .changed: write(s, .number(v))
        case .ended: endGesture()
        }
    }
}

// MARK: - Search

private struct InspectorQueryKey: EnvironmentKey { static let defaultValue = "" }

extension EnvironmentValues {
    /// Text typed into the inspector search box (lowercased); empty shows everything.
    var inspectorQuery: String {
        get { self[InspectorQueryKey.self] }
        set { self[InspectorQueryKey.self] = newValue }
    }
}

extension Field {
    /// Matches the search text by name, label or doc; objects and lists also match through their fields.
    func matches(_ q: String) -> Bool {
        if q.isEmpty { return true }
        if name.lowercased().contains(q) || label.lowercased().contains(q) || doc.lowercased().contains(q) {
            return true
        }
        return subSchema?.fields.contains { $0.matches(q) } ?? false
    }

    var subSchema: ObjectSchema? {
        switch kind {
        case .object(let o), .list(let o), .numberOrObject(let o): return o
        default: return nil
        }
    }

    /// Number range and step when the field is numeric.
    var numberInfo: (min: Double?, max: Double?, step: Double, unit: String?)? {
        switch kind {
        case .number(let lo, let hi, let st, let u): return (lo, hi, st, u)
        case .integer(let lo, let hi): return (lo.map(Double.init), hi.map(Double.init), 1, nil)
        default: return nil
        }
    }
}
