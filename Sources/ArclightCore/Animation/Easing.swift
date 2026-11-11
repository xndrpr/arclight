import Foundation

/// Easing curve. JSON: a name (`"outExpo"`, `"inOutCubic"`, `"linear"`, `"hold"`,
/// `"outBack"`, `"spring"`) or a cubic bezier `[x1, y1, x2, y2]`.
public enum Easing: Equatable, Sendable {
    case linear
    case hold
    case named(String)
    case bezier(Double, Double, Double, Double)

    public static let names: [String] = {
        var n = ["linear", "hold", "spring"]
        for f in ["Sine", "Quad", "Cubic", "Quart", "Quint", "Expo", "Circ", "Back"] {
            n += ["in\(f)", "out\(f)", "inOut\(f)"]
        }
        return n
    }()

    public init(json: JSONValue) throws {
        switch json {
        case .string(let s):
            switch s {
            case "linear": self = .linear
            case "hold": self = .hold
            default:
                guard Easing.names.contains(s) else { throw ModelError.invalid("unknown easing '\(s)'") }
                self = .named(s)
            }
        case .array(let a) where a.count == 4:
            let d = a.compactMap(\.double)
            guard d.count == 4 else { throw ModelError.invalid("bezier easing needs 4 numbers") }
            self = .bezier(d[0], d[1], d[2], d[3])
        default:
            throw ModelError.invalid("easing must be a name or [x1,y1,x2,y2]")
        }
    }

    public init(_ name: String) { self = (try? Easing(json: .string(name))) ?? .linear }

    public var json: JSONValue {
        switch self {
        case .linear: return "linear"
        case .hold: return "hold"
        case .named(let n): return .string(n)
        case .bezier(let a, let b, let c, let d): return [.number(a), .number(b), .number(c), .number(d)]
        }
    }

    public func apply(_ x: Double) -> Double {
        let x = min(max(x, 0), 1)
        switch self {
        case .linear: return x
        case .hold: return x >= 1 ? 1 : 0
        case .bezier(let x1, let y1, let x2, let y2): return Easing.cubicBezier(x, x1, y1, x2, y2)
        case .named(let n): return Easing.named(n, x)
        }
    }

    static func named(_ n: String, _ x: Double) -> Double {
        if n == "spring" {
            // Underdamped spring; cos(4.5π) = 0 so it lands exactly on 1.
            return 1 - exp(-6 * x) * cos(x * 4.5 * .pi)
        }
        let kind: String, fn: String
        if n.hasPrefix("inOut") {
            kind = "inOut"; fn = String(n.dropFirst(5))
        } else if n.hasPrefix("in") {
            kind = "in"; fn = String(n.dropFirst(2))
        } else {
            kind = "out"; fn = String(n.dropFirst(3))
        }
        let f: (Double) -> Double = { t in
            switch fn {
            case "Sine": return 1 - cos(t * .pi / 2)
            case "Quad": return t * t
            case "Cubic": return t * t * t
            case "Quart": return t * t * t * t
            case "Quint": return t * t * t * t * t
            case "Expo": return t == 0 ? 0 : pow(2, 10 * t - 10)
            case "Circ": return 1 - sqrt(max(0, 1 - t * t))
            case "Back": let c = 1.70158; return (c + 1) * t * t * t - c * t * t
            default: return t
            }
        }
        switch kind {
        case "in": return f(x)
        case "out": return 1 - f(1 - x)
        default: return x < 0.5 ? f(2 * x) / 2 : 1 - f(2 - 2 * x) / 2
        }
    }

    static func cubicBezier(_ x: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        func bx(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * x1 + 3 * (1 - t) * t * t * x2 + t * t * t }
        func by(_ t: Double) -> Double { 3 * (1 - t) * (1 - t) * t * y1 + 3 * (1 - t) * t * t * y2 + t * t * t }
        var lo = 0.0, hi = 1.0, t = x
        for _ in 0..<40 {
            t = (lo + hi) / 2
            if bx(t) < x { lo = t } else { hi = t }
        }
        return by(t)
    }
}
