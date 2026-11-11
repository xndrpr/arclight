import ArclightCore
import Foundation

extension MCPServer {
    func editorTools() -> [Tool] {
        [
            Tool(
                name: "editor_state",
                description:
                    "Whether the Arclight editor has this project open (so the user watches your changes live), and what they are looking at: current scene, selected layer (full JSON) and playhead time. Use it to resolve \"this\", \"here\", \"the selected one\". Also lists open notes the user left for you.",
                schema: schema([:]), readOnly: true
            ) { [unowned self] _ in
                let s = try requireStore()
                let watching = Presence.editorHasOpen(s.url)
                var lines = [
                    watching
                        ? "editor: open in Arclight — the user sees your changes live"
                        : "editor: not open in Arclight — the user can't see changes live (they can open it with: arclight open \"\(s.url.path)\")"
                ]
                let f = s.url.appendingPathComponent(".state.json")
                guard let data = try? Data(contentsOf: f),
                    let st = try? JSONDecoder().decode(JSONValue.self, from: data)
                else {
                    lines.append("no editor state yet: the editor has never opened this project")
                    return text(lines.joined(separator: "\n"))
                }
                lines.append(
                    "scene: \(st["scene"]?.string ?? "?")  time: \(st["time"]?.double.map { String(format: "%g", $0) } ?? "0")s"
                        + "  playing: \(st["playing"]?.bool ?? false)  updated: \(st["updated"]?.string ?? "?")"
                        + (watching ? "" : " (last session)"))
                if let sel = st["selection"]?.string, let sc = try? s.scene(st["scene"]?.string), let n = sc.node(sel) {
                    let local = (st["time"]?.double ?? 0) - (n.start ?? 0)
                    lines.append("selected (local t=\(String(format: "%g", local))s, rev \(sc.rev)): " + compactJSON(n))
                } else {
                    lines.append("nothing selected")
                }
                let open = Notes.load(project: s.url).filter(\.isOpen)
                if !open.isEmpty {
                    lines.append("open notes from the user (address them, then note_resolve):")
                    lines += open.map { "  " + Notes.describe($0) }
                }
                return text(lines.joined(separator: "\n"))
            },

            Tool(
                name: "note_list",
                description:
                    "Notes the user left for you in the editor (requests tied to a scene, layer and time). Default: open notes.",
                schema: schema([
                    "status": prop(
                        "string", "open (default), resolved or all", extra: ["enum": ["open", "resolved", "all"]])
                ]), readOnly: true
            ) { [unowned self] a in
                let s = try requireStore()
                let status = a["status"]?.string ?? "open"
                let all = Notes.load(project: s.url)
                let shown = status == "all" ? all : all.filter { status == "resolved" ? !$0.isOpen : $0.isOpen }
                if shown.isEmpty { return text(status == "all" ? "no notes" : "no \(status) notes") }
                return text(shown.map(Notes.describe).joined(separator: "\n"))
            },

            Tool(
                name: "note_resolve",
                description:
                    "Mark a user's note done after addressing it, with an optional short reply the user sees in the editor.",
                schema: schema(
                    [
                        "id": prop("string", "Note id, e.g. n-ab12cd"),
                        "reply": prop("string", "What you did, one line"),
                    ], required: ["id"])
            ) { [unowned self] a in
                let s = try requireStore()
                let n = try Notes.resolve(try a.str("id"), reply: a["reply"]?.string, project: s.url)
                return text("resolved " + Notes.describe(n))
            },

            Tool(
                name: "history",
                description:
                    "List a scene's saved revisions, or restore one with revert_to (saved as a new rev; nothing is lost).",
                schema: schema(
                    [
                        "scene": prop("string", "Scene id"),
                        "revert_to": prop("integer", "Rev to restore"),
                        "limit": prop("integer", "Entries to list, default 15"),
                    ], required: ["scene"])
            ) { [unowned self] a in
                let s = try requireStore()
                let id = try a.str("scene")
                if let r = a["revert_to"]?.double {
                    let rev = try SafeNumber.int(r, "revert_to", in: 0...SafeNumber.maxCount)
                    let saved = try s.revert(id, to: rev, source: .ai)
                    return text(
                        "restored rev \(rev) as rev \(saved.rev)\n" + Outline.scene(saved, project: s.project))
                }
                let limit = try SafeNumber.int(a["limit"]?.double ?? 15, "limit", in: 0...SafeNumber.maxCount)
                let entries = s.history(id).suffix(limit)
                return text(entries.map { "rev \($0.rev)  \($0.time)  \($0.summary)" }.joined(separator: "\n"))
            },
        ]
    }
}
