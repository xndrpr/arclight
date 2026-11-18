import Foundation

/// What the AI should know in every chat of a project — the script, the rules of the piece, which models to use:
/// `<project>/.arclight/context.md`. Written by the user (the chat's Notes button) and sent with each message, so
/// a new chat doesn't start from nothing and nothing has to be pasted twice.
public enum ProjectNotes {
    public static let maxLength = 12000

    public static func url(_ project: URL) -> URL { project.appendingPathComponent(".arclight/context.md") }

    public static func read(_ project: URL) -> String? {
        guard let s = try? String(contentsOf: url(project), encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : String(t.prefix(maxLength))
    }

    public static func write(_ text: String, project: URL) throws {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
        let u = url(project)
        if t.isEmpty { try? FileManager.default.removeItem(at: u); return }
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (t + "\n").write(to: u, atomically: true, encoding: .utf8)
    }
}
