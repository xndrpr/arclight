import Foundation

/// Where Arclight keeps its files outside projects.
public enum AppPaths {
    static let folderName = "Arclight"

    /// `~/Library/Application Support/Arclight`
    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(
            folderName)
    }

    /// `~/Library/Application Support/Arclight/library/<kind>`: user "templates", "themes" or "symbols".
    public static func library(_ kind: String) -> URL {
        support.appendingPathComponent("library").appendingPathComponent(kind)
    }

    /// `~/Library/Logs/Arclight`
    public static var logs: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs").appendingPathComponent(
            folderName)
    }

    /// `~/Library/Caches/Arclight/thumbs`
    public static var thumbs: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(folderName).appendingPathComponent("thumbs")
    }

    /// `~/Movies/Arclight`, the default folder for new projects.
    public static var defaultProjects: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies").appendingPathComponent(
            folderName)
    }
}
