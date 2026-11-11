import Foundation

extension Schema {
    private static func defaultText(_ f: Field) -> String {
        f.defaultValue.map { " Default \($0.compactDescription)." } ?? ""
    }

    private static func fieldLines(_ fields: [Field], indent: String = "  ") -> String {
        fields.map { f in
            "\(indent)\(f.name) (\(f.kind.name)) — \(f.doc)\(defaultText(f))"
                + (f.canDisable ? " Set false to turn off." : "") + (f.animatable ? "" : " Not animatable.")
        }.joined(separator: "\n")
    }

    /// Nested objects referenced by a list of fields (for "see below" sections).
    private static func nestedObjects(_ fields: [Field]) -> [ObjectSchema] {
        var out: [ObjectSchema] = [], seen = Set<String>()
        func visit(_ fs: [Field]) {
            for f in fs {
                let o: ObjectSchema?
                switch f.kind {
                case .object(let x), .list(let x), .numberOrObject(let x): o = x
                default: o = nil
                }
                if let o, seen.insert(o.name).inserted { out.append(o); visit(o.fields) }
            }
        }
        visit(fields)
        return out
    }

    /// Reference text for one layer type (used by the MCP guide).
    public static func reference(type: String) -> String {
        guard let n = node(type) else { return "" }
        var s = "# \(type) — \(n.label)\(n.is3D ? " (3D)" : "")\n\(n.doc)\nProperties:\n" + fieldLines(n.fields)
        for o in nestedObjects(n.fields) { s += "\n\n## \(o.name) {…} — \(o.doc)\n" + fieldLines(o.fields) }
        return s
    }

    public static var transformReference: String {
        "# Common properties (every layer)\n" + fieldLines(transform)
    }

    public static var sceneReference: String {
        var s = "# Scene settings (scene_create args / scene_apply {\"op\":\"scene\"})\n" + fieldLines(sceneFields)
        for o in nestedObjects(sceneFields) { s += "\n\n## \(o.name) {…} — \(o.doc)\n" + fieldLines(o.fields) }
        return s
    }

    /// Full reference as Markdown (written to docs/scene-format.md by `arclight docs`).
    public static func markdown() -> String {
        var md =
            "# Arclight scene format\n\nGenerated from the schema in `Sources/ArclightCore/Schema/`. Do not edit by hand.\n\n"
            + "A colour is \"#RRGGBB\", \"#RRGGBBAA\", [r, g, b, a] (0–1), a name, a theme token such as \"$fg\", "
            + "or a token colour at NN % alpha (0–100) such as \"$fg@25\".\n\n"
        func table(_ fields: [Field]) -> String {
            "| Property | Kind | Default | Description |\n|---|---|---|---|\n"
                + fields.map { f in
                    "| `\(f.name)` | \(f.kind.name.replacingOccurrences(of: "|", with: "\\|")) | \(f.defaultValue.map { "`\($0.compactDescription)`" } ?? "") | \(f.doc)\(f.canDisable ? " `false` turns it off." : "")\(f.animatable ? "" : " Not animatable.") |"
                }.joined(separator: "\n")
        }
        md += "## Common properties\n\n" + table(transform) + "\n\n"
        for n in nodes {
            md +=
                "## `\(n.type)` — \(n.label)\n\n\(n.doc)\n\n"
                + (n.fields.isEmpty ? "_Only the common properties._" : table(n.fields)) + "\n\n"
        }
        md += "## Scene settings\n\n" + table(sceneFields) + "\n\n"
        for o in nestedObjects(sceneFields + nodes.flatMap(\.fields)) {
            md += "### `\(o.name)` object\n\n\(o.doc)\n\n" + table(o.fields) + "\n\n"
        }
        return md
    }
}
