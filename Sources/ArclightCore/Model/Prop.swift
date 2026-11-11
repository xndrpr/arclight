import Foundation

/// An animatable property: a constant, keyframes, or a JavaScript expression.
///
/// JSON forms:
/// - constant: `42`, `"#fff"`, `[1, 2]`
/// - keyframes: `{"k": [[0, 0], [0.6, 45, "outExpo"]]}` — `[t, value, ease?]`, t in node-local seconds.
///   The ease on a keyframe shapes the segment *arriving* at it.
/// - expression: `{"expr": "Math.sin(t * 2) * 20"}`
public enum Prop: Codable, Equatable, Sendable {
    case value(JSONValue)
    case keys([Keyframe])
    case expr(String)

    public init(from decoder: Decoder) throws {
        let v = try JSONValue(from: decoder)
        self = try Prop(json: v)
    }

    public init(json v: JSONValue) throws {
        if case .object(let o) = v {
            if let k = o["k"], case .array(let items) = k, o.count == 1 {
                self = .keys(try items.map(Keyframe.init(json:)).sorted { $0.t < $1.t })
                return
            }
            if let e = o["expr"], case .string(let s) = e, o.count == 1 {
                self = .expr(s)
                return
            }
        }
        self = .value(v)
    }

    public var json: JSONValue {
        switch self {
        case .value(let v): return v
        case .keys(let ks): return .object(["k": .array(ks.map(\.json))])
        case .expr(let s): return .object(["expr": .string(s)])
        }
    }

    public func encode(to encoder: Encoder) throws { try json.encode(to: encoder) }

    public var isAnimated: Bool { if case .value = self { return false }; return true }
    public var keyCount: Int { if case .keys(let k) = self { return k.count }; return 0 }
}

public struct Keyframe: Equatable, Sendable {
    public var t: Double
    public var v: JSONValue
    public var ease: Easing?

    public init(t: Double, v: JSONValue, ease: Easing? = nil) { self.t = t; self.v = v; self.ease = ease }

    public init(json: JSONValue) throws {
        switch json {
        case .array(let a) where a.count >= 2:
            guard let t = a[0].double else { throw ModelError.invalid("keyframe time must be a number") }
            self.t = t; self.v = a[1]
            self.ease = a.count > 2 ? try Easing(json: a[2]) : nil
        case .object(let o):
            guard let t = o["t"]?.double, let v = o["v"] else { throw ModelError.invalid("keyframe needs t and v") }
            self.t = t; self.v = v
            self.ease = try o["ease"].map(Easing.init(json:))
        default:
            throw ModelError.invalid("keyframe must be [t, v, ease?]")
        }
    }

    public var json: JSONValue {
        var a: [JSONValue] = [.number(t), v]
        if let e = ease { a.append(e.json) }
        return .array(a)
    }
}

public enum ModelError: Error, CustomStringConvertible {
    case invalid(String)
    case notFound(String)
    public var description: String {
        switch self {
        case .invalid(let s): return s
        case .notFound(let s): return "not found: \(s)"
        }
    }
}
