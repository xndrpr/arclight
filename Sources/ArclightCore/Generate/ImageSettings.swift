import Foundation

/// Non-secret image settings shared by the editor and the MCP server: a small JSON file in Application Support,
/// which both processes can read (a shared UserDefaults suite would need an app group).
public enum ImageSettings {
    static var url: URL { AppPaths.support.appendingPathComponent("image-settings.json") }

    struct Stored: Codable { var models: FalProvider.Models?; var enabled: Bool? }

    /// Read once per process (and after each write); Settings is the only writer.
    nonisolated(unsafe) private static var memo: Stored?

    static func read() -> Stored {
        if let m = memo { return m }
        let s = JSONFile.read(Stored.self, from: url) ?? Stored()
        memo = s
        return s
    }

    static func write(_ s: Stored) {
        memo = s
        try? JSONFile.write(s, to: url, encoder: JSONEncoder())
    }

    public static var models: FalProvider.Models {
        get { read().models ?? FalProvider.Models() }
        set { var s = read(); s.models = newValue; write(s) }
    }

    /// Generation on/off switch in Settings (on by default; nothing runs without a key either way).
    public static var enabled: Bool {
        get { read().enabled ?? true }
        set { var s = read(); s.enabled = newValue; write(s) }
    }
}
