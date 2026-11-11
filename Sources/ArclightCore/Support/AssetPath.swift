import Foundation

public enum AssetPath {
    /// An asset `src`: an absolute path as is, anything else relative to the project's assets folder.
    public static func url(_ src: String, assets: URL?) -> URL {
        src.hasPrefix("/")
            ? URL(fileURLWithPath: src) : (assets ?? URL(fileURLWithPath: ".")).appendingPathComponent(src)
    }
}
