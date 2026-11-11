import ArclightCore
import Foundation

/// Theme preset tools: restyle the whole project (colours + fonts) in one call.
extension MCPServer {
    static let themePresetListTool = "theme_presets"

    func themeTools() -> [Tool] {
        [
            Tool(
                name: MCPServer.themePresetListTool,
                description:
                    "List theme presets (built-in and the user's saved ones) with their tokens. Apply one with theme_apply to restyle every scene at once.",
                schema: schema([:]), readOnly: true
            ) { [unowned self] _ in
                let current = store.flatMap { ThemePresets.current($0.project.theme) }
                let lines = ThemePresets.all().map { p -> String in
                    let tag = (p.isBuiltIn ? "" : " [saved]") + (p.id == current?.id ? " [current]" : "")
                    return "\(p.id) — \(p.name)\(tag): \(p.description ?? "")\n  tokens: " + compactJSON(p.tokens)
                }
                return text(
                    lines.joined(separator: "\n") + "\nStandard tokens: "
                        + ThemePresets.standardKeys.map { "$\($0) (\(ThemePresets.describe($0) ?? ""))" }.joined(
                            separator: ", "))
            },

            Tool(
                name: "theme_apply",
                description:
                    "Apply a theme preset to the project: its colour and font tokens replace the current ones; other custom tokens are kept. Every scene using $tokens restyles.",
                schema: schema(
                    ["preset": prop("string", "Preset id or name from theme_presets, e.g. \"midnight\"")],
                    required: ["preset"])
            ) { [unowned self] a in
                let s = try requireStore()
                let name = try a.str("preset")
                guard let preset = ThemePresets.get(name) else {
                    throw ToolError(
                        "unknown preset '\(name)' — available: \(ThemePresets.all().map(\.id).joined(separator: ", "))")
                }
                var p = s.project
                p.theme = ThemePresets.applying(preset, to: p.theme)
                try s.update(project: p)
                return text("applied \(preset.name) — theme: " + compactJSON(p.theme))
            },

            Tool(
                name: "theme_preset_save",
                description:
                    "Save the project's current theme tokens as a reusable preset in the user's library (available in every project).",
                schema: schema(
                    [
                        "name": prop("string", "Preset name, e.g. \"Brand dark\""),
                        "description": prop("string", "Optional one-line description"),
                    ], required: ["name"])
            ) { [unowned self] a in
                let s = try requireStore()
                let saved = try ThemePresets.save(
                    name: try a.str("name"), tokens: s.project.theme, description: a["description"]?.string)
                return text("saved preset \(saved.id) (\(saved.tokens.count) tokens)")
            },
        ]
    }
}
