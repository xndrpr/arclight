import ArclightCore
import Foundation

// The activity log is shown live in the editor's Activity panel.
extension MCPServer {
    func isReadOnly(_ tool: String) -> Bool { tools.first { $0.name == tool }?.readOnly ?? false }

    static func sceneArg(_ tool: String, _ a: [String: JSONValue]) -> String? {
        if let s = a["scene"]?.string { return s }
        if tool == "scene_create" { return a["id"]?.string }
        return nil
    }

    /// One-line description of a call, e.g. "add crowd; set stat; remove pools".
    static func describe(_ tool: String, _ a: [String: JSONValue]) -> String {
        func ids(_ o: [String: JSONValue]) -> String {
            if let n = o["node"]?.object?["id"]?.string { return n }
            if let i = o["id"]?.string { return i }
            if let l = o["ids"]?.array?.compactMap(\.string) { return l.joined(separator: ",") }
            return ""
        }
        switch tool {
        case "scene_apply":
            let ops = a["ops"]?.array?.compactMap(\.object) ?? []
            let parts = ops.map { o -> String in
                let op = o["op"]?.string ?? "?"
                if op == "scene" { return "scene " + o.keys.filter { $0 != "op" }.sorted().joined(separator: ",") }
                let fields = o.keys.filter {
                    !["op", "id", "ids", "node", "before", "after", "index", "as"].contains($0)
                }.sorted()
                let target = ids(o) + (op == "duplicate" ? " → \(o["as"]?.string ?? "")" : "")
                return "\(op) \(target)"
                    + (op == "set" && !fields.isEmpty ? " (\(fields.prefix(4).joined(separator: ", ")))" : "")
            }
            return parts.prefix(6).joined(separator: "; ") + (parts.count > 6 ? "; +\(parts.count - 6) more" : "")
        case "scene_create":
            return "create scene \(a["id"]?.string ?? "?") with \(a["nodes"]?.array?.count ?? 0) layers"
        case "scene_get":
            if let i = a["ids"]?.array?.compactMap(\.string) { return "read layers " + i.joined(separator: ", ") }
            return a["full"]?.bool == true ? "read full scene" : "read scene outline"
        case "scene_delete": return "delete scene \(a["scene"]?.string ?? "")"
        case "render_frames":
            let t = a["times"]?.doubles?.map { String(format: "%g", $0) }.joined(separator: ", ") ?? "4 frames"
            return "preview at t = \(t)"
        case "export":
            let sc = a["scenes"]?.array?.compactMap(\.string).joined(separator: ", ") ?? "all scenes"
            return "export \(sc) as \(a["format"]?.string ?? "mp4")"
        case "theme_set": return "theme " + (a["tokens"]?.object?.keys.sorted().joined(separator: ", ") ?? "")
        case "theme_apply": return "apply theme " + (a["preset"]?.string ?? "")
        case "project_update": return "project " + a.keys.sorted().joined(separator: ", ")
        case "project_open", "project_create":
            return (tool == "project_open" ? "open " : "create ")
                + URL(fileURLWithPath: a["path"]?.string ?? "").lastPathComponent
        case "history":
            if let r = a["revert_to"]?.double {
                return "revert \(a["scene"]?.string ?? "") to rev \(SafeNumber.describe(r))"
            }
            return "list history"
        case "editor_state": return "read what you have open"
        case "template_list": return "list templates"
        case "symbol_list": return "list symbols"
        case "project_check": return "check project for problems"
        case "template_instantiate":
            return "new scene \(a["scene"]?.string ?? "") from template \(a["template"]?.string ?? "")"
        case "template_save": return "save scene \(a["scene"]?.string ?? "") as template \(a["id"]?.string ?? "")"
        case "note_list": return "read notes" + (a["status"]?.string.map { " (\($0))" } ?? "")
        case "note_resolve":
            return "resolve note \(a["id"]?.string ?? "?")" + (a["reply"]?.string.map { " — \($0)" } ?? "")
        case "project_get": return "read project summary"
        case "guide": return "read guide" + (a["topic"]?.string.map { " (\($0))" } ?? "")
        case "asset_import": return "import " + URL(fileURLWithPath: a["path"]?.string ?? "").lastPathComponent
        case "asset_write": return "write asset " + (a["name"]?.string ?? "")
        case "symbol_save": return "save symbol " + (a["pack"]?.string ?? "") + "/" + (a["id"]?.string ?? "")
        case "font_list": return "list fonts" + (a["query"]?.string.map { " “\($0)”" } ?? "")
        default: return tool
        }
    }

    /// Logs a call to the project's activity feed; returns whether it changed the project.
    /// Read-only calls are logged too (with `write: false`), by design: the editor's activity feed is this file, and
    /// it shows what the agent looked at. So a read appends to `.arclight/activity.jsonl` and touches nothing else.
    @discardableResult
    func log(_ tool: String, _ args: [String: JSONValue], sceneId: String?, before: Scene?, error: String?) -> Bool {
        lastCallFailed = error != nil
        guard let s = store else { return false }
        try? s.reload()
        let after = sceneId.flatMap { s.scenes[$0] }
        let changedScene = before?.rev != after?.rev
        let diff = changedScene && after != nil ? SceneDiff.diff(before, after!) : nil
        let write = !isReadOnly(tool) && (error == nil ? (changedScene || sceneId == nil) : false)
        var detail = compactJSON(JSONValue.object(args))
        if detail.count > 4000 { detail = String(detail.prefix(4000)) + "…" }
        ActivityLog.append(
            ActivityEntry(
                source: .ai, tool: tool, scene: sceneId, summary: MCPServer.describe(tool, args),
                changed: diff?.all.isEmpty == false ? diff?.all : nil,
                revBefore: before?.rev, revAfter: after?.rev, ok: error == nil, error: error, write: write,
                detail: detail,
                agent: presence.client.map(AgentPresence.displayName)), project: s.url)
        return write
    }
}
