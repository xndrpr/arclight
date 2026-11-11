import Foundation

#if canImport(Darwin)
    import Darwin
#endif

/// One AI agent session connected through `arclight mcp` (one server process per session, stdio).
/// The server keeps `<presence dir>/agents/<pid>.json` up to date; the editor polls the folder to show
/// who is connected and what they are doing. Files of dead processes are treated as gone and deleted.
public struct AgentPresence: Codable, Equatable, Identifiable, Sendable {
    public var pid: Int32
    /// MCP `initialize` clientInfo (e.g. "claude-code"), nil until the client said hello.
    public var client: String?
    public var clientVersion: String?
    /// ISO 8601 times.
    public var started: String
    public var lastCall: String?
    /// Tool running right now (nil between calls).
    public var tool: String?
    /// Whether the running tool can change the project (vs. a read like scene_get).
    public var toolWrites: Bool?
    public var lastTool: String?
    /// One-line description of the last call ("add crowd; set stat").
    public var lastSummary: String?
    public var lastWrite: Bool?
    public var lastOk: Bool?
    /// Project the agent is working on now (standardized path), and every project it opened this session.
    public var project: String?
    public var projects: [String]

    public var id: Int32 { pid }

    public init(
        pid: Int32, client: String? = nil, clientVersion: String? = nil, started: Date = Date(), project: String? = nil
    ) {
        self.pid = pid; self.client = client; self.clientVersion = clientVersion
        self.started = Timestamp.string(started)
        self.project = project
        self.projects = project.map { [$0] } ?? []
    }

    public enum Activity: String, Sendable { case idle, reading, editing }

    /// How recently a finished call still counts as "reading…/editing…".
    public static let busyWindow: TimeInterval = 4

    /// What the agent is doing at `now`: a call in progress, or one that finished in the last few seconds.
    public func activity(now: Date = Date()) -> Activity {
        if tool != nil { return toolWrites == true ? .editing : .reading }
        if let d = lastCallDate, now.timeIntervalSince(d) < Self.busyWindow {
            return lastWrite == true ? .editing : .reading
        }
        return .idle
    }

    public var startedDate: Date? { Timestamp.parse(started) }
    public var lastCallDate: Date? { lastCall.flatMap(Timestamp.parse) }

    /// "Claude Code", "Cursor"… from the MCP client name; "AI agent" when unknown.
    public var displayName: String { Self.displayName(client) }

    /// Whether the agent opened (or is working on) a project folder.
    public func uses(_ project: URL) -> Bool {
        let p = Presence.key(project)
        return self.project == p || projects.contains(p)
    }

    /// Records the start of a tool call.
    public mutating func begin(_ tool: String, writes: Bool) {
        self.tool = tool; toolWrites = writes
    }

    /// Records a finished tool call.
    public mutating func end(summary: String, wrote: Bool, ok: Bool, project: String?, at date: Date = Date()) {
        lastTool = tool; tool = nil; toolWrites = nil
        lastSummary = summary; lastWrite = wrote; lastOk = ok
        lastCall = Timestamp.string(date)
        if let project {
            self.project = project
            if !projects.contains(project) { projects.append(project) }
        }
    }

    public static func displayName(_ client: String?) -> String {
        guard let raw = client?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return "AI agent" }
        let c = raw.lowercased()
        let known: [(String, String)] = [
            ("claude-code", "Claude Code"), ("claude code", "Claude Code"), ("claude", "Claude"),
            ("cursor", "Cursor"), ("codex", "Codex"), ("windsurf", "Windsurf"), ("gemini", "Gemini CLI"),
            ("visual studio code", "VS Code"), ("vscode", "VS Code"), ("copilot", "GitHub Copilot"),
            ("zed", "Zed"), ("cline", "Cline"), ("goose", "Goose"), ("continue", "Continue"), ("opencode", "opencode"),
        ]
        if let k = known.first(where: { c.contains($0.0) }) { return k.1 }
        return raw.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// An Arclight editor process and the projects it has open (`<presence dir>/editors/<pid>.json`), so the MCP
/// server can tell an agent whether the user is watching.
public struct EditorPresence: Codable, Equatable, Sendable {
    public var pid: Int32
    public var projects: [String]
    public var updated: String

    public init(pid: Int32, projects: [String], updated: Date = Date()) {
        self.pid = pid; self.projects = projects; self.updated = Timestamp.string(updated)
    }
}

/// Presence files shared by `arclight mcp` processes and the editor.
public enum Presence {
    /// `~/Library/Application Support/Arclight` (override with `ARCLIGHT_PRESENCE_DIR`, e.g. for tests). The old
    /// `APOGEE_PRESENCE_DIR` is still read, so setups from before the rename keep working.
    static var root: URL {
        let env = ProcessInfo.processInfo.environment
        if let o = env["ARCLIGHT_PRESENCE_DIR"] ?? env["APOGEE_PRESENCE_DIR"], !o.isEmpty {
            return URL(fileURLWithPath: o)
        }
        return AppPaths.support
    }
    /// How project folders are compared across processes: absolute, standardized, symlinks resolved.
    public static func key(_ project: URL) -> String { project.standardizedFileURL.resolvingSymlinksInPath().path }

    public static var agentsDir: URL { root.appendingPathComponent("agents") }
    public static var editorsDir: URL { root.appendingPathComponent("editors") }

    // MARK: Agents

    public static func write(_ a: AgentPresence, dir: URL = agentsDir) {
        save(a, to: dir.appendingPathComponent("\(a.pid).json"))
    }
    public static func remove(pid: Int32, dir: URL = agentsDir) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(pid).json"))
    }

    /// Connected agents, oldest first. Entries whose process is gone are deleted (unless `prune` is false).
    public static func agents(
        dir: URL = agentsDir, alive: (Int32) -> Bool = isArclightProcess, prune: Bool = true
    ) -> [AgentPresence] {
        load(AgentPresence.self, dir: dir, pid: \.pid, alive: alive, prune: prune)
            .sorted { ($0.started, $0.pid) < ($1.started, $1.pid) }
    }

    // MARK: Editors

    public static func write(_ e: EditorPresence, dir: URL = editorsDir) {
        let f = dir.appendingPathComponent("\(e.pid).json")
        if e.projects.isEmpty { try? FileManager.default.removeItem(at: f) } else { save(e, to: f) }
    }

    public static func editors(
        dir: URL = editorsDir, alive: (Int32) -> Bool = isAlive, prune: Bool = true
    ) -> [EditorPresence] {
        load(EditorPresence.self, dir: dir, pid: \.pid, alive: alive, prune: prune)
    }

    /// Whether a running editor has this project open.
    public static func editorHasOpen(_ project: URL, dir: URL = editorsDir, alive: (Int32) -> Bool = isAlive) -> Bool {
        let p = Presence.key(project)
        return editors(dir: dir, alive: alive).contains { $0.projects.contains(p) }
    }

    // MARK: Processes

    /// The process exists (signal 0 succeeds, or exists but belongs to someone else).
    public static func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// The process exists and is an `arclight` binary, or an `apogee` one from before the rename (guards against pid
    /// reuse and against signalling anything else).
    public static func isArclightProcess(_ pid: Int32) -> Bool {
        guard isAlive(pid) else { return false }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return true }  // can't tell: trust liveness
        let name = URL(fileURLWithPath: String(cString: buf)).lastPathComponent.lowercased()
        return name.hasPrefix("arclight") || name.hasPrefix("apogee")
    }

    // MARK: Helpers

    private static func save<T: Encodable>(_ v: T, to f: URL) {
        try? JSONFile.write(v, to: f, encoder: JSONFormat.compact())
    }

    private static func load<T: Decodable>(
        _ type: T.Type, dir: URL, pid: KeyPath<T, Int32>, alive: (Int32) -> Bool, prune: Bool
    ) -> [T] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let dec = JSONDecoder()
        var out: [T] = []
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f), let v = try? dec.decode(T.self, from: data) else { continue }
            if alive(v[keyPath: pid]) { out.append(v) } else if prune { try? fm.removeItem(at: f) }
        }
        return out
    }
}
