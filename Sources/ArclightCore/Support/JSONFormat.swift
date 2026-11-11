import Foundation

/// The JSON encodings Arclight writes. Keep each call site's format: changing it changes files on disk or MCP text.
public enum JSONFormat {
    /// Sorted keys, pretty-printed, slashes unescaped: every JSON file a person may read or diff.
    public static func pretty() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    /// Sorted keys on one line, slashes unescaped: JSONL logs, presence files and MCP text.
    public static func compact() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

/// Whole-file JSON reads and writes.
public enum JSONFile {
    /// The decoded file, or nil when it is missing or invalid.
    public static func read<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    /// Creates the parent folder and writes atomically.
    public static func write<T: Encodable>(_ value: T, to url: URL, encoder: JSONEncoder = JSONFormat.pretty()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

/// Append-only JSON Lines files.
public enum JSONL {
    /// Appends one line (compact by default), creating the file and its folder. Returns the file size after writing, or
    /// nil when the value can't be encoded or the file can't be opened.
    @discardableResult
    public static func append<T: Encodable>(
        _ value: T, to url: URL, encoder: JSONEncoder = JSONFormat.compact()
    ) -> UInt64? {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let line = try? encoder.encode(value), let h = try? FileHandle(forWritingTo: url) else { return nil }
        h.seekToEndOfFile()
        h.write(line + Data("\n".utf8))
        let size = h.offsetInFile
        try? h.close()
        return size
    }
}
