import ArclightCore
import Foundation

extension MCPServer {
    /// A project canvas size, checked the same way by project_create and project_update.
    static func canvasSize(_ v: JSONValue) throws -> [Int] {
        let message = "size must be [width, height], each from 16 to \(SafeNumber.maxCanvas)"
        guard let size = v.doubles, size.count == 2 else { throw ToolError(message) }
        do {
            return try size.map { try SafeNumber.int($0, "size", in: 16...SafeNumber.maxCanvas) }
        } catch { throw ToolError(message) }
    }

    /// A project frame rate, checked the same way by project_create and project_update.
    static func frameRate(_ v: JSONValue) throws -> Double {
        guard let f = v.double, f > 0 else { throw ToolError("fps must be > 0") }
        return try SafeNumber.positive(f, "fps", max: SafeNumber.maxFPS)
    }

    func projectTools() -> [Tool] {
        [
            Tool(
                name: "guide",
                description:
                    "Scene format reference, generated from the engine's schema. Call once per session before building scenes. Topics: \(Guide.topicNames.joined(separator: ", ")); omit for all.",
                schema: schema([
                    "topic": prop(
                        "string", "One topic, or omit for the full reference",
                        extra: ["enum": .array((Guide.topicNames + Guide.aliases.keys.sorted()).map { .string($0) })])
                ]), readOnly: true
            ) { a in
                if let t = a["topic"]?.string {
                    guard let g = Guide.topic(t) else {
                        throw ToolError("unknown topic '\(t)' — topics: \(Guide.topicNames.joined(separator: ", "))")
                    }
                    return text(g)
                }
                return text(Guide.all)
            },

            Tool(
                name: "project_create",
                description: "Create a new project folder (use a .arclight extension) and open it.",
                schema: schema(
                    [
                        "path": prop("string", "Folder path, e.g. ~/Videos/Episode12.arclight"),
                        "name": prop("string", "Display name"),
                        "size": prop(
                            "array", "[width, height], default [1920,1080]", extra: ["items": ["type": "integer"]]),
                        "fps": prop("number", "Default 30"),
                    ], required: ["path"])
            ) { [unowned self] a in
                let url = URL(expandingPath: try a.str("path"))
                if FileManager.default.fileExists(atPath: url.appendingPathComponent("project.json").path) {
                    throw ToolError("a project already exists there — use project_open")
                }
                // Validate before anything is created on disk.
                let size = try a["size"].map(MCPServer.canvasSize)
                let fps = try a["fps"].map(MCPServer.frameRate)
                let s = try ProjectStore.create(
                    at: url, name: a["name"]?.string ?? url.deletingPathExtension().lastPathComponent)
                var p = s.project
                if let size { p.size = size }
                if let fps { p.fps = fps }
                try s.update(project: p)
                store = s
                return text(projectSummary(s))
            },

            Tool(
                name: "project_open",
                description: "Open an existing project folder. Returns size, fps, theme tokens and scenes.",
                schema: schema(["path": prop("string", "Project folder path")], required: ["path"]), readOnly: true
            ) { [unowned self] a in
                let s = try ProjectStore(url: URL(expandingPath: try a.str("path")))
                store = s
                return text(projectSummary(s))
            },

            Tool(
                name: "project_get",
                description:
                    "Summary of the open project: size, fps, theme tokens, scenes with duration/node count/rev.",
                schema: schema([:]), readOnly: true
            ) { [unowned self] _ in text(projectSummary(try requireStore())) },

            Tool(
                name: "project_update",
                description:
                    "Change project name, canvas size (e.g. [1080,1920] for vertical 9:16) or frame rate. Per-scene overrides: scene_apply {op:\"scene\", size, fps}.",
                schema: schema([
                    "name": prop("string", "Display name"),
                    "size": prop("array", "[width, height]", extra: ["items": ["type": "integer"]]),
                    "fps": prop("number", "e.g. 24, 25, 30, 60"),
                ])
            ) { [unowned self] a in
                let s = try requireStore()
                var p = s.project
                if let n = a["name"]?.string, !n.isEmpty { p.name = n }
                if let size = a["size"] { p.size = try MCPServer.canvasSize(size) }
                if let f = a["fps"] { p.fps = try MCPServer.frameRate(f) }
                try s.update(project: p)
                return text(projectSummary(s))
            },

            Tool(
                name: "theme_set",
                description:
                    "Merge design tokens into the project theme (referenced from props as \"$name\"). null deletes a token. Use for colors, fonts, sizes shared across scenes.",
                schema: schema(
                    ["tokens": prop("object", "e.g. {\"fg\":\"#F2EFE6\",\"display\":\"Oswald-Bold\",\"accent\":null}")],
                    required: ["tokens"])
            ) { [unowned self] a in
                let s = try requireStore()
                guard let tokens = a["tokens"]?.object else { throw ToolError("tokens must be an object") }
                var p = s.project
                for (k, v) in tokens { if v == .null { p.theme[k] = nil } else { p.theme[k] = v } }
                try s.update(project: p)
                return text("theme: " + compactJSON(p.theme))
            },

            Tool(
                name: "font_list",
                description:
                    "List installed font PostScript names. Filter by substring; cyrillic:true keeps fonts that cover Russian.",
                schema: schema([
                    "query": prop("string", "Substring, e.g. \"condensed\" or \"Oswald\""),
                    "cyrillic": prop("boolean", "Only fonts with Cyrillic glyphs"),
                ]), readOnly: true
            ) { a in
                let names = Fonts.list(query: a["query"]?.string, cyrillic: a["cyrillic"]?.bool ?? false)
                let shown = names.prefix(150)
                return text(
                    shown.joined(separator: "\n")
                        + (names.count > shown.count ? "\n… \(names.count - shown.count) more; narrow the query" : ""))
            },
        ]
    }
}
