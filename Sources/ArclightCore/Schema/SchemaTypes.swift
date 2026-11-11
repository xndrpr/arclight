import Foundation

/// What a property holds. Drives the inspector widgets, validation and the generated docs.
public indirect enum FieldKind: Sendable {
    case number(min: Double? = nil, max: Double? = nil, step: Double = 1, unit: String? = nil)
    case integer(min: Int? = nil, max: Int? = nil)
    case bool
    case color
    /// Colour or gradient `{"linear":[…]|"radial":[…],"stops":[…]}`.
    case paint
    case string(multiline: Bool = false)
    case font
    case choice([String])
    case vector(labels: [String], unit: String? = nil)
    /// A number, or a vector with the given labels (e.g. scale 1 or [sx, sy]).
    case numberOrVector(labels: [String])
    /// A number shorthand, or an object for full control (e.g. bloom 0.5 or {intensity, threshold}).
    case numberOrObject(ObjectSchema)
    case object(ObjectSchema)
    case list(ObjectSchema)
    case easing
    case asset(String)
    case symbol
    /// Anything JSON (escape hatch, edited as code).
    case json

    /// A number or a whole number.
    var isNumeric: Bool {
        switch self {
        case .number, .integer: return true
        default: return false
        }
    }

    /// The settings of an object field (`.object`, or the object form of `.numberOrObject`).
    var objectSchema: ObjectSchema? {
        switch self {
        case .object(let o), .numberOrObject(let o): return o
        default: return nil
        }
    }

    public var name: String {
        switch self {
        case .number(_, _, _, let u): return u.map { "number (\($0))" } ?? "number"
        case .integer: return "integer"
        case .bool: return "bool"
        case .color: return "color"
        case .paint: return "color or gradient"
        case .string: return "string"
        case .font: return "font"
        case .choice(let o): return o.map { "\"\($0)\"" }.joined(separator: "|")
        case .vector(let l, _): return "[" + l.joined(separator: ", ") + "]"
        case .numberOrVector(let l): return "number or [" + l.joined(separator: ", ") + "]"
        case .numberOrObject(let o): return "number or {\(o.name)}"
        case .object(let o): return "{\(o.name)}"
        case .list(let o): return "[{\(o.name)}]"
        case .easing: return "easing"
        case .asset(let k): return "\(k) file"
        case .symbol: return "symbol id"
        case .json: return "JSON"
        }
    }
}

public struct Field: Sendable {
    public let name: String
    public let label: String
    public let kind: FieldKind
    public let doc: String
    public let defaultValue: JSONValue?
    public let animatable: Bool
    /// Hidden behind "More" in the inspector.
    public let advanced: Bool
    /// The object may be set to `false` to turn it off (e.g. "ground": false).
    public let canDisable: Bool

    public init(
        _ name: String, _ kind: FieldKind, _ doc: String, label: String? = nil, default def: JSONValue? = nil,
        animatable: Bool = true, advanced: Bool = false, canDisable: Bool = false
    ) {
        self.name = name; self.kind = kind; self.doc = doc; self.defaultValue = def
        self.animatable = animatable; self.advanced = advanced; self.canDisable = canDisable
        self.label = label ?? Field.humanize(name)
    }

    private static func humanize(_ s: String) -> String {
        var out = ""
        for c in s { if c.isUppercase { out += " " + c.lowercased() } else { out.append(c) } }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}

public struct ObjectSchema: Sendable {
    public let name: String
    public let doc: String
    public let fields: [Field]
    public init(_ name: String, _ doc: String, _ fields: [Field]) {
        self.name = name; self.doc = doc; self.fields = fields
    }
    public func field(_ n: String) -> Field? { fields.first { $0.name == n } }
}

public struct NodeSchema: Sendable {
    public let type: String
    public let label: String
    /// SF Symbol name for the editor.
    public let icon: String
    public let doc: String
    public let fields: [Field]
    public let is3D: Bool
}
