import Foundation

/// Which model the in-app chat talks to. Raw values are the provider's model ids (stored in chat settings).
public enum ChatModel: String, CaseIterable, Codable, Sendable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"
    case haiku = "claude-haiku-5-5"

    public var label: String {
        switch self {
        case .opus: return "Opus 5.5"
        case .sonnet: return "Sonnet 5.5"
        case .haiku: return "Haiku 5.5"
        }
    }

    /// Opus and Sonnet re-run a declined request on a fallback model server-side; Haiku has no fallback.
    var hasServerFallback: Bool { self != .haiku }
}

/// How hard the model thinks before answering (`output_config.effort`).
public enum ChatEffort: String, CaseIterable, Codable, Sendable {
    case low, medium, high
    public var label: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Where chat turns run: the provider's API with the user's key (everyone), or the user's own installed command-line
/// agent (experimental, behind a flag; see `ChatSettings.cliAllowed`).
public enum ChatBackendKind: String, Codable, Sendable {
    case api, cli
}

/// What a running turn reports to the UI, in order.
public enum ChatEvent: Sendable, Equatable {
    case text(String)
    case thinking(String)
    /// A tool call started (`id` matches its `toolEnd`). `input` is the arguments as compact JSON.
    case toolStart(id: String, name: String, input: String)
    /// `summary` is the tool's text output (shortened); `image` the first picture it returned (JPEG/PNG bytes).
    case toolEnd(id: String, ok: Bool, summary: String, image: Data?)
    /// Something the user should know that isn't the model's words (cut off, declined, retrying…).
    case notice(String)
}

/// One row of the chat as the user sees it. The model's own history lives in `ChatTranscript.history`.
public struct ChatItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case user, assistant, thinking, tool, notice, error }
    public var id: String
    public var kind: Kind
    public var text: String
    /// Tool rows: the tool's name, its arguments (compact JSON), whether it succeeded (nil while running).
    public var tool: String?
    public var input: String?
    public var ok: Bool?
    /// Tool rows: the first image the tool returned (kept in memory only; not saved with the transcript).
    public var image: Data?

    public init(
        id: String = UUID().uuidString, kind: Kind, text: String, tool: String? = nil, input: String? = nil,
        ok: Bool? = nil
    ) {
        self.id = id; self.kind = kind; self.text = text; self.tool = tool; self.input = input; self.ok = ok
    }

    enum CodingKeys: String, CodingKey { case id, kind, text, tool, input, ok }
}

/// A project's chat, saved at `<project>/.arclight/chat.json` so it survives closing the project.
public struct ChatTranscript: Codable, Equatable, Sendable {
    /// What the user sees.
    public var items: [ChatItem] = []
    /// API backend: the Messages API conversation exactly as sent and received (append-only; thinking blocks kept
    /// unchanged, as the API requires).
    public var history: [JSONValue] = []
    /// CLI backend: the agent's session id, resumed on the next turn.
    public var cliSession: String?

    public init() {}

    public static func url(_ project: URL) -> URL {
        project.appendingPathComponent(LegacyMigration.hiddenFolder).appendingPathComponent("chat.json")
    }

    public static func load(project: URL) -> ChatTranscript {
        JSONFile.read(ChatTranscript.self, from: url(project)) ?? ChatTranscript()
    }

    public func save(project: URL) {
        try? JSONFile.write(self, to: Self.url(project), encoder: JSONEncoder())
    }

    /// Folds one event into the visible rows: text and thinking deltas extend the last row of their kind.
    public mutating func apply(_ e: ChatEvent) {
        switch e {
        case .text(let s): extend(.assistant, s)
        case .thinking(let s): extend(.thinking, s)
        case .toolStart(let id, let name, let input):
            items.append(ChatItem(id: id, kind: .tool, text: "", tool: name, input: input))
        case .toolEnd(let id, let ok, let summary, let image):
            if let i = items.lastIndex(where: { $0.id == id }) {
                items[i].ok = ok; items[i].text = summary; items[i].image = image
            }
        case .notice(let s): items.append(ChatItem(kind: .notice, text: s))
        }
    }

    private mutating func extend(_ kind: ChatItem.Kind, _ s: String) {
        if let last = items.last, last.kind == kind {
            items[items.count - 1].text += s
        } else {
            items.append(ChatItem(kind: kind, text: s))
        }
    }
}

/// Chat settings that aren't secret (the API key is in `KeychainStore.chatKey`). A small JSON file in Application
/// Support, like `ImageSettings`.
public enum ChatSettings {
    struct Stored: Codable {
        var model: ChatModel?
        var effort: ChatEffort?
        var backend: ChatBackendKind?
        var cliPath: String?
    }

    nonisolated(unsafe) public static var overrideURL: URL? { didSet { memo = nil } }
    nonisolated(unsafe) private static var memo: Stored?
    static var url: URL { overrideURL ?? AppPaths.support.appendingPathComponent("chat-settings.json") }

    static func read() -> Stored {
        if let m = memo { return m }
        let s = JSONFile.read(Stored.self, from: url) ?? Stored()
        memo = s
        return s
    }

    static func update(_ f: (inout Stored) -> Void) {
        var s = read()
        f(&s)
        memo = s
        try? JSONFile.write(s, to: url)
    }

    public static var model: ChatModel {
        get { read().model ?? .opus }
        set { update { $0.model = newValue } }
    }

    public static var effort: ChatEffort {
        get { read().effort ?? .medium }
        set { update { $0.effort = newValue } }
    }

    /// The chosen backend. The CLI one counts only while it is allowed (the experimental flag is on).
    public static var backend: ChatBackendKind {
        get { cliAllowed() ? (read().backend ?? .api) : .api }
        set { update { $0.backend = newValue } }
    }

    /// A path to the command-line agent set by hand (empty: look in the usual places).
    public static var cliPath: String {
        get { read().cliPath ?? "" }
        set { update { $0.cliPath = newValue.isEmpty ? nil : newValue } }
    }

    /// The experimental "use my installed command-line agent" backend is hidden unless turned on deliberately:
    /// `defaults write com.xndrpr.arclight experimental.cliChat -bool true` or `ARCLIGHT_EXPERIMENTAL_CLI_CHAT=1`.
    /// It runs on the user's own agent login and subscription, which provider terms may not allow for an app that is
    /// handed to other people, so it is off for everyone by default.
    public static func cliAllowed(
        defaults: UserDefaults = .standard, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let v = environment["ARCLIGHT_EXPERIMENTAL_CLI_CHAT"] { return v == "1" || v.lowercased() == "true" }
        return defaults.bool(forKey: cliFlagKey)
    }

    public static let cliFlagKey = "experimental.cliChat"
}
