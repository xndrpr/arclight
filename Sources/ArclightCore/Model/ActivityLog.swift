import Foundation

/// One thing that happened to a project: an MCP tool call by an AI agent, or an editor save.
public struct ActivityEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var time: String
    /// A `ChangeSource` raw value: "claude" (any AI agent), "editor" or "cli".
    public var source: String
    /// Display name of the AI agent for MCP calls ("Claude Code", "Cursor"); nil in older logs and for the editor.
    public var agent: String?
    /// MCP tool name, or "edit" for editor saves.
    public var tool: String
    public var scene: String?
    /// One-line human summary ("add crowd; set stat").
    public var summary: String
    /// Node ids added, removed or modified.
    public var changed: [String]?
    public var revBefore: Int?
    public var revAfter: Int?
    public var ok: Bool
    public var error: String?
    /// True if the call changed the project (vs. a read like scene_get / render_frames).
    public var write: Bool
    /// Compact request detail (e.g. the ops JSON), truncated, for an expandable view.
    public var detail: String?

    public init(
        source: ChangeSource, tool: String, scene: String? = nil, summary: String, changed: [String]? = nil,
        revBefore: Int? = nil, revAfter: Int? = nil, ok: Bool = true, error: String? = nil, write: Bool,
        detail: String? = nil, agent: String? = nil
    ) {
        self.id = String(UUID().uuidString.prefix(8)).lowercased()
        self.time = Timestamp.string()
        self.source = source.rawValue; self.tool = tool; self.scene = scene; self.summary = summary
        self.changed = changed; self.revBefore = revBefore; self.revAfter = revAfter
        self.ok = ok; self.error = error; self.write = write; self.detail = detail
        self.agent = agent
    }

    /// Whether this came from an AI agent (MCP).
    public var isAI: Bool { source == ChangeSource.ai.rawValue }

    /// "Claude Code", "AI" for agent calls of unknown name, "You", "Command line".
    public var who: String {
        switch ChangeSource(rawValue: source) {
        case .ai: return agent ?? "AI"
        case .cli: return "Command line"
        default: return "You"
        }
    }

    public var date: Date? { Timestamp.parse(time) }
}

/// Append-only activity feed at `<project>/.arclight/activity.jsonl`, shared by the MCP server and the editor.
public enum ActivityLog {
    public static func url(_ project: URL) -> URL {
        project.appendingPathComponent(LegacyMigration.hiddenFolder).appendingPathComponent("activity.jsonl")
    }

    /// Appends one entry (best effort; logging never fails the caller). Keeps the file under ~2 MB.
    public static func append(_ e: ActivityEntry, project: URL) {
        let f = url(project)
        if let size = JSONL.append(e, to: f), size > 2_000_000 { trim(f, keep: 2000) }
    }

    /// The most recent `limit` entries, oldest first.
    public static func read(project: URL, limit: Int = 500) -> [ActivityEntry] {
        guard let s = try? String(contentsOf: url(project), encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return s.split(separator: "\n").suffix(limit).compactMap {
            try? dec.decode(ActivityEntry.self, from: Data($0.utf8))
        }
    }

    private static func trim(_ f: URL, keep: Int) {
        guard let s = try? String(contentsOf: f, encoding: .utf8) else { return }
        let lines = s.split(separator: "\n").suffix(keep)
        try? (lines.joined(separator: "\n") + "\n").write(to: f, atomically: true, encoding: .utf8)
    }
}

/// Which nodes differ between two versions of a scene.
public enum SceneDiff {
    public struct Result: Equatable, Sendable {
        public var added: [String] = []
        public var removed: [String] = []
        public var modified: [String] = []
        public var sceneChanged = false
        public var all: [String] { added + removed + modified }
        public var isEmpty: Bool { all.isEmpty && !sceneChanged }

        /// "added crowd; removed pools; changed stat, label".
        public var summary: String {
            var parts: [String] = []
            func list(_ ids: [String]) -> String {
                ids.prefix(4).joined(separator: ", ") + (ids.count > 4 ? " +\(ids.count - 4)" : "")
            }
            if !added.isEmpty { parts.append("added " + list(added)) }
            if !removed.isEmpty { parts.append("removed " + list(removed)) }
            if !modified.isEmpty { parts.append("changed " + list(modified)) }
            if sceneChanged { parts.append("scene settings") }
            return parts.isEmpty ? "no changes" : parts.joined(separator: "; ")
        }
    }

    public static func diff(_ a: Scene?, _ b: Scene) -> Result {
        var r = Result()
        let old = Dictionary((a?.nodes ?? []).map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        let new = Dictionary(b.nodes.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        for n in b.nodes {
            if let o = old[n.id] { if o != n { r.modified.append(n.id) } } else { r.added.append(n.id) }
        }
        for n in a?.nodes ?? [] where new[n.id] == nil { r.removed.append(n.id) }
        if let a {
            r.sceneChanged =
                a.duration != b.duration || a.background != b.background || a.camera != b.camera
                || a.fog != b.fog || a.post != b.post || a.size != b.size || a.fps != b.fps || a.name != b.name
            // Pure reorders count as modified layers.
            if r.all.isEmpty, a.nodes.map(\.id) != b.nodes.map(\.id) { r.modified = b.nodes.map(\.id) }
        }
        return r
    }
}
