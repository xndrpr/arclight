import Foundation

/// What the user wants this project to sound like, kept in `.arclight/sound.md`: the palette, levels they liked,
/// sounds they rejected and why. Agents add to it after every reaction to a sound and read it before the next
/// sound edit, so a preference is never asked for (or got wrong) twice — also in a new chat.
public enum SoundNotes {
    public static let maxLength = 4000

    public static func url(_ project: URL) -> URL { project.appendingPathComponent(".arclight/sound.md") }

    public static func read(_ project: URL) -> String? {
        guard let s = try? String(contentsOf: url(project), encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    public static func write(_ text: String, project: URL) throws {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxLength))
        let u = url(project)
        if t.isEmpty { try? FileManager.default.removeItem(at: u); return }
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (t + "\n").write(to: u, atomically: true, encoding: .utf8)
    }

    /// Adds one line, dated by the caller if it matters; the oldest lines fall off when the notes get too long.
    public static func add(_ line: String, project: URL) throws -> String {
        let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !l.isEmpty else { return read(project) ?? "" }
        var lines = (read(project) ?? "").split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let entry = l.hasPrefix("- ") ? l : "- " + l
        if !lines.contains(entry) { lines.append(entry) }
        while lines.joined(separator: "\n").count > maxLength, lines.count > 1 { lines.removeFirst() }
        try write(lines.joined(separator: "\n"), project: project)
        return lines.joined(separator: "\n")
    }
}
