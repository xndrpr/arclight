import ArclightCore
import Foundation

extension MCPServer {
    /// Throws the scene's validation problems, if any.
    func validate(_ scene: Scene) throws {
        let issues = Validator.validate(scene, expr: try renderer().evaluator.expr)
        if !issues.isEmpty {
            throw ToolError("not saved — fix these:\n" + issues.map { "- \($0)" }.joined(separator: "\n"))
        }
    }

    func saveValidated(_ scene: Scene, store s: ProjectStore, expectedRev: Int?, summary: String) throws -> Scene {
        try validate(scene)
        return try s.save(scene: scene, expectedRev: expectedRev, summary: summary, source: .ai)
    }

    func applyReport(_ scene: Scene, changed: [String], store s: ProjectStore) -> String {
        var lines = [
            "saved \(scene.id) rev \(scene.rev) (\(scene.nodes.count) nodes, \(String(format: "%g", scene.duration))s)"
        ]
        let shown = changed.prefix(12).compactMap { scene.node($0) }
        lines += shown.map { "  " + Outline.node($0) }
        if changed.count > shown.count { lines.append("  … \(changed.count - shown.count) more") }
        // Fonts that are not installed silently fall back, so say so.
        let ev = Evaluator(theme: s.project.theme)
        var missing = Set<String>()
        for n in scene.nodes where n.type == "text" {
            let f = Doctor.fontName(of: n, evaluator: ev)
            if !f.isEmpty && !Fonts.exists(f) { missing.insert(f) }
        }
        if !missing.isEmpty {
            lines.append(
                "warning: font(s) not installed, using fallback: \(missing.sorted().joined(separator: ", ")) — see font_list"
            )
        }
        return lines.joined(separator: "\n")
    }

    func projectSummary(_ s: ProjectStore) -> String {
        let p = s.project
        var lines = [
            "project \(p.name)  \(p.size.map(String.init).joined(separator: "x"))@\(String(format: "%g", p.fps))  \(s.url.path)",
            "theme: " + compactJSON(p.theme),
        ]
        if s.orderedScenes.isEmpty { lines.append("no scenes yet") }
        for sc in s.orderedScenes {
            lines.append(
                "scene \(sc.id)  \(String(format: "%g", sc.duration))s  \(sc.nodes.count) nodes  rev \(sc.rev)")
        }
        return lines.joined(separator: "\n")
    }
}
