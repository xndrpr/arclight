import Foundation

/// The chat's system prompt, request body and the conversions between MCP tool output and API content blocks.
public enum ChatPrompt {
    /// Frozen for the whole conversation (it heads the cached prompt prefix): no times, no editor state.
    public static func system(instructions: String, projectPath: String) -> String {
        """
        You are the AI assistant built into the Arclight editor. The user is chatting with you in the editor's AI \
        panel while looking at their project, and sees every change you make live.

        The project at \(projectPath) is already open: the tools work on it, so don't call project_open or \
        project_create unless the user asks for another project. Each user message may start with a short note on \
        what the editor shows right now (workspace, open scene or thumbnail, selection, playhead); use it to resolve \
        "this", "the selected layer" and so on.

        Keep replies short: say what you changed, not how. After visual changes, render a frame at low scale and \
        look at it before saying you're done. Every change is listed in the AI panel with one-click revert.

        Arclight's own notes for agents:
        \(instructions)
        """
    }

    /// The Messages API request body and the beta flags it needs.
    public static func request(
        model: ChatModel, effort: ChatEffort, system: String, tools: [MCPToolInfo], messages: [JSONValue]
    ) -> (body: JSONValue, beta: [String]) {
        var body: [String: JSONValue] = [
            "model": .string(model.rawValue),
            "max_tokens": 64000,
            "stream": true,
            "system": [["type": "text", "text": .string(system)]],
            // Sorted, so the tool list (the start of the cached prefix) is byte-identical on every request.
            "tools": .array(tools.sorted { $0.name < $1.name }.map(tool)),
            "messages": .array(messages),
            "thinking": ["type": "adaptive", "display": "summarized"],
            "output_config": ["effort": .string(effort.rawValue)],
            // Caches the conversation up to its newest message; the next request reads it back.
            "cache_control": ["type": "ephemeral"],
        ]
        var beta: [String] = []
        if model.hasServerFallback {
            // A request the model declines is re-run on a fallback model inside the same call.
            body["fallbacks"] = "default"
            beta.append("server-side-fallback-2026-07-01")
        }
        return (.object(body), beta)
    }

    static func tool(_ t: MCPToolInfo) -> JSONValue {
        var schema = t.inputSchema.object ?? [:]
        if schema["type"] == nil { schema["type"] = "object" }
        return [
            "name": .string(t.name), "description": .string(t.description), "input_schema": .object(schema),
            // Big inputs (whole scenes) stream as they're written; the engine checks the JSON before running a tool.
            "eager_input_streaming": true,
        ]
    }

    /// MCP content blocks → `tool_result` content: text stays text, images become base64 image blocks (so the model
    /// can look at what it rendered), anything else becomes its JSON as text.
    public static func toolContent(_ mcp: [JSONValue]) -> [JSONValue] {
        let out: [JSONValue] = mcp.map { b in
            switch b["type"]?.string {
            case "text":
                return ["type": "text", "text": .string(b["text"]?.string ?? "")]
            case "image":
                return [
                    "type": "image",
                    "source": [
                        "type": "base64", "media_type": .string(b["mimeType"]?.string ?? "image/png"),
                        "data": .string(b["data"]?.string ?? ""),
                    ],
                ]
            default:
                return ["type": "text", "text": .string(compact(b))]
            }
        }
        return out.isEmpty ? [["type": "text", "text": "(no output)"]] : out
    }

    /// The tool's text output, shortened for the chat row.
    public static func summary(_ mcp: [JSONValue], limit: Int = 400) -> String {
        let s = mcp.compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > limit ? String(s.prefix(limit)) + "…" : s
    }

    public static func firstImage(_ mcp: [JSONValue]) -> Data? {
        mcp.first { $0["type"]?.string == "image" }?["data"]?.string.flatMap { Data(base64Encoded: $0) }
    }

    public static func compact(_ v: JSONValue) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(v)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    /// What the chat says when the model declines (`stop_reason: refusal`).
    static func declined(_ details: JSONValue?) -> String {
        if let c = details?["category"]?.string { return "The model declined this request (\(c))." }
        return "The model declined this request."
    }

    /// The note on what the editor shows, put at the start of each user message.
    public static func editorNote(
        workspace: String, target: String?, selection: [String], time: Double?
    ) -> String {
        var parts = ["workspace: \(workspace)"]
        if let target { parts.append("open: \(target)") }
        if !selection.isEmpty { parts.append("selected: \(selection.joined(separator: ", "))") }
        if let time { parts.append(String(format: "playhead: %.2fs", time)) }
        return "<editor>" + parts.joined(separator: " · ") + "</editor>"
    }
}
