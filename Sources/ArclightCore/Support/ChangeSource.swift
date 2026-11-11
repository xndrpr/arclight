/// Who changed a project, as stored in activity logs and history. The raw values are file format.
public enum ChangeSource: String, Codable, Sendable {
    /// Any AI agent through MCP (stored as "claude" for every agent, as older projects have it).
    case ai = "claude"
    /// The editor app.
    case editor
    /// The command line.
    case cli
}
