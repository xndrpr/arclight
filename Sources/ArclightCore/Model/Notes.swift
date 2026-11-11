import Foundation

/// A request the user leaves for the AI agent while watching ("make this slower", "wrong color here").
public struct Note: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var scene: String
    /// Layer the note is about (the editor's selection when it was written).
    public var layer: String?
    /// Scene time (seconds) the note is about (the playhead when it was written).
    public var time: Double?
    /// "open" or "resolved".
    public var status: String
    public var created: String
    public var resolvedAt: String?
    /// The AI agent's answer when resolving.
    public var reply: String?

    public init(text: String, scene: String, layer: String? = nil, time: Double? = nil) {
        id = "n-" + String(UUID().uuidString.prefix(6)).lowercased()
        self.text = text; self.scene = scene; self.layer = layer; self.time = time
        status = "open"
        created = Timestamp.string()
    }

    public var isOpen: Bool { status != "resolved" }
    public var resolvedDate: Date? { resolvedAt.flatMap(Timestamp.parse) }

    /// "stat-45 · title @ 2.4s"
    public var target: String {
        var s = scene
        if let layer { s += " · " + layer }
        if let time { s += " @ " + String(format: "%gs", (time * 100).rounded() / 100) }
        return s
    }
}

/// Notes for the AI agent at `<project>/.arclight/notes.json` (oldest first), shared by the editor and the MCP server.
public enum Notes {
    static func url(_ project: URL) -> URL {
        project.appendingPathComponent(LegacyMigration.hiddenFolder).appendingPathComponent("notes.json")
    }

    public static func load(project: URL) -> [Note] {
        JSONFile.read([Note].self, from: url(project)) ?? []
    }

    static func save(_ notes: [Note], project: URL) throws {
        try JSONFile.write(notes, to: url(project))
    }

    @discardableResult
    public static func add(_ note: Note, project: URL) throws -> Note {
        var all = load(project: project)
        all.append(note)
        try save(all, project: project)
        return note
    }

    /// Marks a note resolved (with an optional reply). Throws if there is no such note.
    @discardableResult
    public static func resolve(_ id: String, reply: String? = nil, project: URL) throws -> Note {
        var all = load(project: project)
        guard let i = all.firstIndex(where: { $0.id == id }) else { throw ModelError.notFound("note '\(id)'") }
        all[i].status = "resolved"
        all[i].resolvedAt = Timestamp.string()
        if let r = reply?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty { all[i].reply = r }
        try save(all, project: project)
        return all[i]
    }

    /// Re-opens a resolved note (editor "reopen").
    public static func reopen(_ id: String, project: URL) throws {
        var all = load(project: project)
        guard let i = all.firstIndex(where: { $0.id == id }) else { throw ModelError.notFound("note '\(id)'") }
        all[i].status = "open"; all[i].resolvedAt = nil
        try save(all, project: project)
    }

    public static func delete(_ id: String, project: URL) throws {
        try save(load(project: project).filter { $0.id != id }, project: project)
    }

    /// One line per note for MCP output: `n-ab12cd  [open]  stat-45 · title @ 2.4s  “make it slower”`.
    public static func describe(_ n: Note) -> String {
        var s = "\(n.id)  [\(n.status)]  \(n.target)  “\(n.text)”"
        if let r = n.reply { s += "  → \(r)" }
        return s
    }
}
