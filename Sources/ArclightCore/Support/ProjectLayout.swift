import Foundation

/// Fixed names inside a project folder.
public enum ProjectLayout {
    /// The hidden per-project folder (activity log, notes, chats, caches).
    public static let hiddenFolder = ".arclight"
    public static let projectFile = "project.json"
    public static let scenes = "scenes"
    public static let thumbnails = "thumbnails"
    public static let assets = "assets"
    /// Default folder for exported videos and stills.
    public static let exports = "exports"
    /// Project templates and symbol packs (the user library has folders of the same names).
    public static let templates = "templates"
    public static let symbols = "symbols"
    /// Scene and thumbnail revisions, one folder per id.
    public static let history = ".history"

    /// `<project>/.arclight/<path>`.
    public static func hidden(_ path: String, in project: URL) -> URL {
        project.appendingPathComponent(hiddenFolder).appendingPathComponent(path)
    }
}
