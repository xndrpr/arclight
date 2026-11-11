import Foundation

public struct ValidationIssue: Equatable, CustomStringConvertible, Sendable {
    public var node: String?
    public var message: String
    /// True for an expression that fails to compile or run; false for structure and schema problems.
    public var isExpression = false
    public var description: String { node.map { "\($0): \(message)" } ?? message }
}

/// Validation = structure (ids, parents, timing) + the schema (property names, kinds, ranges, choices)
/// + things only the engine can know (symbols, SVG paths, expressions that compile and run).
public enum Validator {
    public static func validate(_ scene: Scene, expr: ExprEngine? = nil) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        if scene.duration <= 0 { issues.append(.init(node: nil, message: "duration must be > 0")) }
        issues += Schema.checkScene(scene).map { .init(node: nil, message: $0) }
        var seen = Set<String>()
        let byId = Dictionary(scene.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for n in scene.nodes {
            func bad(_ m: String, expression: Bool = false) {
                issues.append(.init(node: n.id, message: m, isExpression: expression))
            }
            if n.id.isEmpty { bad("empty id") }
            if !seen.insert(n.id).inserted { bad("duplicate id") }
            guard Node.types.contains(n.type) else {
                bad(
                    "unknown type '\(n.type)' (expected \(Node.types.sorted().joined(separator: ", ")))"
                        + Schema.suggestion(n.type, Array(Node.types)))
                continue
            }
            if let p = n.parent {
                if byId[p] == nil { bad("parent '\(p)' does not exist") }
                var cur: String? = p, hops = 0
                while let c = cur, hops <= scene.nodes.count {
                    if c == n.id { bad("parent cycle"); break }; cur = byId[c]?.parent; hops += 1
                }
            }
            if let s = n.start, let e = n.end, e <= s { bad("out must be after in") }
            Schema.check(n).forEach { bad($0) }

            switch n.type {
            case "text": if n.props["text"] == nil { bad("text layer needs 'text'") }
            case "image": if n.props["src"] == nil { bad("image layer needs 'src'") }
            case "symbol":
                if case .value(let v)? = n.props["symbol"], let sym = v.string, let msg = missingBuiltIn(sym) {
                    bad("symbol \(msg)")
                }
            case "repeater":
                if case .value(let v)? = n.props["items"], let items = v.array?.compactMap(\.object) {
                    for (k, item) in items.enumerated() {
                        if let sym = item["symbol"]?.string, let msg = missingBuiltIn(sym) {
                            bad("items[\(k)].symbol \(msg)")
                        }
                        if item["path"] != nil {
                            do { _ = try SVGPath.sprite(item) } catch { bad("items[\(k)]: \(error)") }
                        }
                    }
                }
                if case .value(let v)? = n.props["instance"], let o = v.object, let expr {
                    for (k, raw) in o {
                        guard case .expr(let src)? = try? Prop(json: raw) else { continue }
                        if let err = expr.compileError(src) {
                            bad("instance.\(k): \(err)", expression: true)
                            continue
                        }
                        if k != "color", expr.evalBatch(src, t: 0, T: 0, d: scene.duration, n: 8) == nil {
                            bad("instance.\(k): fails when evaluated for all instances", expression: true)
                        }
                    }
                }
            default: break
            }
            if let expr {
                for (k, p) in n.props {
                    if case .expr(let src) = p, let err = expr.compileError(src) {
                        bad("\(k): \(err)", expression: true)
                    }
                }
            }
        }
        return issues
    }

    /// "'basic/nope' not found — available: …" for a missing symbol of a built-in pack. Project and user packs are
    /// resolved at render time (Doctor checks them), so other ids are never reported here.
    private static func missingBuiltIn(_ sym: String) -> String? {
        guard sym.hasPrefix("basic/") || sym.hasPrefix("chess/"), !Symbols.exists(sym) else { return nil }
        let pack = sym.split(separator: "/").first.map(String.init) ?? ""
        return
            "'\(sym)' not found — available: \(Symbols.all().filter { $0.pack == pack }.map(\.id).joined(separator: ", "))"
    }
}
