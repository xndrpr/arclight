import Foundation

extension URL {
    /// A file or folder from a typed path (CLI argument, MCP argument): `~` expanded, then standardized.
    public init(expandingPath path: String) {
        self = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }
}
