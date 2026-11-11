import Foundation

/// Project-wide health check: everything that would render wrong or not at all.
public struct Problem: Equatable, Sendable, Identifiable {
    public enum Severity: String, Sendable { case error, warning }
    public var severity: Severity
    /// "schema", "font", "asset", "symbol", "token", "expression".
    public var kind: String
    public var scene: String
    public var node: String?
    public var message: String
    public var id: String { "\(scene)|\(node ?? "")|\(message)" }
    /// "error [font] intro/title: …", as `project_check` and `arclight check` print it.
    public var line: String { "\(severity.rawValue) [\(kind)] \(scene)\(node.map { "/" + $0 } ?? ""): \(message)" }
}

public enum Doctor {
    /// One problem per line, or "no problems".
    public static func report(_ problems: [Problem]) -> String {
        problems.isEmpty ? "no problems" : problems.map(\.line).joined(separator: "\n")
    }

    public static func check(_ store: ProjectStore, expr: ExprEngine = ExprEngine()) -> [Problem] {
        var out: [Problem] = []
        let theme = store.project.theme
        let ev = Evaluator(theme: theme, expr: expr)
        for scene in store.orderedScenes {
            for i in Validator.validate(scene, expr: expr) {
                out.append(
                    Problem(
                        severity: .error, kind: i.isExpression ? "expression" : "schema", scene: scene.id,
                        node: i.node, message: i.message))
            }
            func tokens(_ v: JSONValue, into set: inout Set<String>) {
                switch v {
                case .string(let s) where s.hasPrefix("$") && s.count > 1:
                    // "$accent@25" uses the token "accent" (unless the theme has a key "accent@25").
                    var name = String(s.dropFirst())
                    if theme[name] == nil, let (base, _) = Evaluator.alphaSuffix(s) { name = String(base.dropFirst()) }
                    set.insert(name)
                case .array(let a): a.forEach { tokens($0, into: &set) }
                case .object(let o): o.values.forEach { tokens($0, into: &set) }
                default: break
                }
            }
            func propTokens(_ p: Prop?) -> Set<String> {
                var set = Set<String>()
                switch p {
                case .value(let v)?: tokens(v, into: &set)
                case .keys(let ks)?: ks.forEach { tokens($0.v, into: &set) }
                default: break
                }
                return set
            }
            for (name, p) in [
                ("background", scene.background), ("camera", scene.camera), ("fog", scene.fog), ("post", scene.post),
            ] {
                for t in propTokens(p).sorted() where theme[t] == nil {
                    out.append(
                        Problem(
                            severity: .warning, kind: "token", scene: scene.id, node: nil,
                            message: "\(name) uses $\(t), which is not in the theme"))
                }
            }
            for n in scene.nodes {
                var used = Set<String>()
                for (_, p) in n.props { used.formUnion(propTokens(p)) }
                for t in used.sorted() where theme[t] == nil {
                    out.append(
                        Problem(
                            severity: .warning, kind: "token", scene: scene.id, node: n.id,
                            message: "uses $\(t), which is not in the theme"))
                }
                if n.type == "text" {
                    let f = fontName(of: n, evaluator: ev)
                    if !f.isEmpty, !f.hasPrefix("$"), !Fonts.exists(f) {
                        out.append(
                            Problem(
                                severity: .warning, kind: "font", scene: scene.id, node: n.id,
                                message:
                                    "font '\(f)' is not installed — falls back to Helvetica (add it to the project's fonts/ folder)"
                            ))
                    }
                }
                if case .value(let v)? = n.props["src"], let src = v.string, !src.isEmpty, !exists(src, store) {
                    out.append(
                        Problem(
                            severity: .error, kind: "asset", scene: scene.id, node: n.id,
                            message: "image '\(src)' not found in assets/"))
                }
                if n.type == "symbol" {
                    let sym =
                        n.props["symbol"].flatMap {
                            if case .value(let v) = $0 { return v.string }; return nil
                        } ?? Schema.defaultSymbol
                    if !sym.hasPrefix("$"), !Symbols.exists(sym, project: store.url) {
                        out.append(
                            Problem(
                                severity: .error, kind: "symbol", scene: scene.id, node: n.id,
                                message: "symbol '\(sym)' not found (see symbol_list) — the layer draws nothing"))
                    }
                }
                if n.type == "repeater", case .value(let v)? = n.props["items"] {
                    for (k, item) in (v.array ?? []).enumerated() {
                        if let src = item["src"]?.string, !exists(src, store) {
                            out.append(
                                Problem(
                                    severity: .error, kind: "asset", scene: scene.id, node: n.id,
                                    message: "items[\(k)] image '\(src)' not found"))
                        }
                        if let sym = item["symbol"]?.string, !sym.hasPrefix("$"),
                            !Symbols.exists(sym, project: store.url)
                        {
                            out.append(
                                Problem(
                                    severity: .error, kind: "symbol", scene: scene.id, node: n.id,
                                    message: "items[\(k)] symbol '\(sym)' not found (see symbol_list)"))
                        }
                    }
                }
            }
            if let a = scene.audio, !a.src.isEmpty, !exists(a.src, store) {
                out.append(
                    Problem(
                        severity: .error, kind: "asset", scene: scene.id, node: nil,
                        message: "audio '\(a.src)' not found in assets/"))
            }
        }
        return out
    }

    /// The font a text layer asks for: its `font`, else the theme's `$display`; "" when neither resolves.
    public static func fontName(of n: Node, evaluator ev: Evaluator) -> String {
        n.props["font"].map { ev.value($0, t: 0, T: 0) }?.string ?? ev.resolve("$display").string ?? ""
    }

    static func exists(_ src: String, _ store: ProjectStore) -> Bool {
        FileManager.default.fileExists(atPath: AssetPath.url(src, assets: store.assetsURL).path)
    }
}
