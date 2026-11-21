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
    /// The model asked the user to decide a direction stage; the turn ends and waits for the answer.
    case choice(ChatChoice)
    /// The model's plan for the request changed (`update_plan`).
    case plan(ChatPlan)
    /// Tokens and cost: one model request's, or the backend's account of the whole turn (see `ChatUsage.Scope`).
    case usage(ChatUsage)
    /// The provider reported how close the account is to its usage limits. Not part of the transcript: the chat
    /// controller keeps the latest.
    case limits(ChatLimits)
}

/// One row of the chat as the user sees it. The model's own history lives in `ChatTranscript.history`.
public struct ChatItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case user, assistant, thinking, tool, notice, error, choice }
    public var id: String
    public var kind: Kind
    public var text: String
    /// Tool rows: the tool's name, its arguments (compact JSON), whether it succeeded (nil while running).
    public var tool: String?
    public var input: String?
    public var ok: Bool?
    /// Tool rows: the first image the tool returned (kept in memory only; not saved with the transcript).
    public var image: Data?
    /// Choice rows: the question, its options and (once given) the user's answer.
    public var choice: ChatChoice?
    /// User rows: the files sent with the message.
    public var attachments: [ChatAttachment]?
    /// Thinking rows: when the thinking started, and how long it took once it ended (nil while it runs).
    /// Tool rows: `duration` is how long the call took, once it ended.
    public var started: Date?
    public var duration: Double?
    /// When the row appeared: a user message when it was sent, the AI's rows when they started. Nil for rows saved
    /// before rows had times.
    public var created: Date?
    /// User rows: where the project stood when the message was sent — each scene's revision, and how long the
    /// model's own history was. Going back to the message ("Edit from here", "Revert this turn") restores these.
    public var checkpoint: [String: Int]?
    public var historyCount: Int?

    public init(
        id: String = UUID().uuidString, kind: Kind, text: String, tool: String? = nil, input: String? = nil,
        ok: Bool? = nil, choice: ChatChoice? = nil, attachments: [ChatAttachment]? = nil, created: Date? = Date()
    ) {
        self.id = id; self.kind = kind; self.text = text; self.tool = tool; self.input = input; self.ok = ok
        self.choice = choice
        self.attachments = attachments
        self.created = created
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, text, tool, input, ok, choice, attachments, started, duration, created, checkpoint
        case historyCount
    }
}

/// One of a project's chats, saved at `<project>/.arclight/chats/<id>.json` so it survives closing the project.
public struct ChatTranscript: Codable, Equatable, Sendable {
    /// What the user sees.
    public var items: [ChatItem] = []
    /// API backend: the Messages API conversation exactly as sent and received (append-only; thinking blocks kept
    /// unchanged, as the API requires).
    public var history: [JSONValue] = []
    /// CLI backend: the agent's session id, resumed on the next turn.
    public var cliSession: String?
    /// The AI's latest plan for the current request (the progress bar).
    public var plan: ChatPlan?
    /// Stable id of this conversation (its file name once archived) and when it started.
    public var id: String = UUID().uuidString
    public var created: Date = Date()
    /// When it was last saved with something new, and the name the user gave it (nil: `title` makes one).
    public var updated: Date?
    public var name: String?
    /// Every turn's time, tokens and cost, in order (none for chats saved before turns were recorded).
    public var turns: [ChatTurn] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case items, history, cliSession, plan, id, created, updated, name, turns }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([ChatItem].self, forKey: .items) ?? []
        history = try c.decodeIfPresent([JSONValue].self, forKey: .history) ?? []
        cliSession = try c.decodeIfPresent(String.self, forKey: .cliSession)
        plan = try? c.decodeIfPresent(ChatPlan.self, forKey: .plan)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        updated = try c.decodeIfPresent(Date.self, forKey: .updated)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        // Usage is a nicety: a chat whose turns don't read still opens.
        turns = (try? c.decodeIfPresent([ChatTurn].self, forKey: .turns)) ?? []
    }

    /// The chat's name in the list: the one the user gave it, else the first thing they said.
    public var title: String {
        if let n = name?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { return n }
        let t = items.first { $0.kind == .user && !$0.text.isEmpty }?.text ?? "New chat"
        let line = t.split(separator: "\n").first.map(String.init) ?? t
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    /// A project's chats: `<project>/.arclight/chats/<id>.json`, one file each, with `index.json` beside them.
    public static func folder(_ project: URL) -> URL {
        project.appendingPathComponent(ProjectLayout.hiddenFolder).appendingPathComponent("chats")
    }

    public static func file(_ id: String, project: URL) -> URL { folder(project).appendingPathComponent("\(id).json") }

    /// The single chat file of projects made before a project could hold several chats.
    static func legacyURL(_ project: URL) -> URL {
        project.appendingPathComponent(ProjectLayout.hiddenFolder).appendingPathComponent("chat.json")
    }

    /// One chat in the list.
    public struct Summary: Identifiable, Equatable, Codable, Sendable {
        public var id: String
        public var title: String
        /// When it last changed.
        public var date: Date
        /// How many messages the user sent.
        public var messages: Int

        public init(id: String, title: String, date: Date, messages: Int) {
            self.id = id; self.title = title; self.date = date; self.messages = messages
        }
    }

    public var summary: Summary {
        Summary(id: id, title: title, date: updated ?? created, messages: items.filter { $0.kind == .user }.count)
    }

    public static func load(_ id: String, project: URL) -> ChatTranscript? {
        JSONFile.read(ChatTranscript.self, from: file(id, project: project))
    }

    /// Writes the chat to its file (an empty chat has nothing to keep).
    public func save(project: URL) {
        guard !items.isEmpty else { return }
        try? JSONFile.write(self, to: Self.file(id, project: project), encoder: JSONEncoder())
    }

    public static func delete(_ id: String, project: URL) {
        try? FileManager.default.removeItem(at: file(id, project: project))
    }

    /// Folds one event into the visible rows: text and thinking deltas extend the last row of their kind. Tool calls
    /// and usage count toward the running turn (`beginTurn`; one is opened if none is).
    public mutating func apply(_ e: ChatEvent, now: Date = Date()) {
        switch e {
        case .thinking, .usage, .limits: break
        default: endThinking(now: now)
        }
        switch e {
        case .text(let s): extend(.assistant, s, now: now)
        case .thinking(let s):
            extend(.thinking, s, now: now)
            if items[items.count - 1].started == nil { items[items.count - 1].started = now }
        case .toolStart(let id, let name, let input):
            items.append(ChatItem(id: id, kind: .tool, text: "", tool: name, input: input, created: now))
            turns[openTurn(now)].tools += 1
        case .toolEnd(let id, let ok, let summary, let image):
            if let i = items.lastIndex(where: { $0.id == id }) {
                items[i].ok = ok; items[i].text = summary; items[i].image = image
                if let t = items[i].created { items[i].duration = max(0, now.timeIntervalSince(t)) }
            }
        case .notice(let s): items.append(ChatItem(kind: .notice, text: s, created: now))
        case .choice(let c):
            items.append(ChatItem(id: c.id, kind: .choice, text: c.question, choice: c, created: now))
            plan?.waiting = true
        case .plan(let p): plan = p
        case .usage(let u):
            let i = openTurn(now)
            turns[i].add(u)
            if u.scope == .turn, u.cost == nil, let total = u.sessionCost {
                // An agent that reports only its running total: this turn cost what the total grew by.
                let before = turns[..<i].last { $0.backend == turns[i].backend && $0.sessionCost != nil }?.sessionCost
                turns[i].cost = before.map { total >= $0 ? total - $0 : total } ?? total
            }
        case .limits: break  // the controller keeps them; they aren't this chat's
        }
    }

    // MARK: Turns

    /// Starts a turn: `item` is the row it answers (the user's message, or the choice card they answered).
    public mutating func beginTurn(item: String?, backend: ChatBackendKind, model: String, now: Date = Date()) {
        endTurn(.stopped, now: now)
        turns.append(ChatTurn(item: item, backend: backend, model: model, started: now))
    }

    /// Ends the running turn, if one is.
    public mutating func endTurn(_ outcome: ChatTurn.Outcome, now: Date = Date()) {
        guard let i = turns.indices.last, turns[i].finished == nil else { return }
        turns[i].finished = max(now, turns[i].started)
        turns[i].outcome = outcome
    }

    /// A turn left running by an app that quit mid-reply ends when the chat was last saved.
    public mutating func closeAbandonedTurn() {
        guard let t = turns.last, t.finished == nil else { return }
        endTurn(.stopped, now: max(t.started, updated ?? t.started))
    }

    /// The turn running now.
    public var currentTurn: ChatTurn? { turns.last.flatMap { $0.finished == nil ? $0 : nil } }

    /// The turn that answered this row (a user message or a choice card), the latest if it was answered more than once.
    public func turn(for item: String) -> ChatTurn? { turns.last { $0.item == item } }

    /// Everything the chat has used, all turns together.
    public var totalTokens: ChatTokens { turns.reduce(ChatTokens()) { $0 + $1.tokens } }

    /// What the chat has cost so far, in US dollars (an estimate), from the turns whose cost is known; nil if none is.
    public var totalCost: Double? {
        let known = turns.compactMap(\.cost)
        return known.isEmpty ? nil : known.reduce(0, +)
    }

    /// How full the context is: the prompt of the latest request, against its model's window (the backend's word for
    /// it, else the price list's).
    public var context: ChatContext? {
        guard let t = turns.last(where: { $0.context != nil }), let used = t.context else { return nil }
        let window =
            t.contextWindow
            ?? turns.last(where: { $0.model == t.model && $0.backend == t.backend && $0.contextWindow != nil })?
            .contextWindow
            ?? t.model.flatMap(ChatPricing.contextWindow)
        return ChatContext(used: used, window: window, model: t.model)
    }

    /// The running turn's index, opening one (answering the last user message) if none is running.
    private mutating func openTurn(_ now: Date) -> Int {
        if let i = turns.indices.last, turns[i].finished == nil { return i }
        let item = items.last { $0.kind == .user }?.id
        turns.append(ChatTurn(item: item, backend: nil, model: nil, started: now))
        return turns.count - 1
    }

    /// The question still waiting for the user, if the last turn ended on one.
    public var pendingChoice: ChatChoice? {
        guard let i = items.lastIndex(where: { $0.kind == .choice }), let c = items[i].choice, c.answer == nil,
            !items[(i + 1)...].contains(where: { $0.kind == .user })
        else { return nil }
        return c
    }

    /// Records the user's answer on the choice row.
    public mutating func answer(_ id: String, _ a: ChatChoice.Answer) {
        if let i = items.lastIndex(where: { $0.id == id && $0.kind == .choice }) { items[i].choice?.answer = a }
    }

    /// Closes a thinking row still running: it gets its duration. Called when anything else arrives and when the
    /// turn ends.
    public mutating func endThinking(now: Date = Date()) {
        guard let i = items.indices.last, items[i].kind == .thinking, items[i].duration == nil else { return }
        items[i].duration = max(0, now.timeIntervalSince(items[i].started ?? now))
    }

    private mutating func extend(_ kind: ChatItem.Kind, _ s: String, now: Date) {
        if let last = items.last, last.kind == kind {
            items[items.count - 1].text += s
        } else {
            items.append(ChatItem(kind: kind, text: s, created: now))
        }
    }
}

/// The list of a project's chats (`chats/index.json`): what the chat list shows without opening every chat file,
/// and which chat was open last.
public struct ChatIndex: Codable, Equatable, Sendable {
    public var active: String?
    /// Newest first.
    public var chats: [ChatTranscript.Summary] = []

    public init() {}

    static func url(_ project: URL) -> URL { ChatTranscript.folder(project).appendingPathComponent("index.json") }

    /// The index, made to agree with the chat files that are there: a chat file it doesn't list is read and added
    /// (an older project, a file copied in), a listed chat whose file is gone is dropped. The single `chat.json` of
    /// an older project is moved in as a chat first.
    public static func load(project: URL) -> ChatIndex {
        let fm = FileManager.default
        var index = JSONFile.read(ChatIndex.self, from: url(project)) ?? ChatIndex()
        let legacy = ChatTranscript.legacyURL(project)
        if let t = JSONFile.read(ChatTranscript.self, from: legacy) {
            if !t.items.isEmpty, !fm.fileExists(atPath: ChatTranscript.file(t.id, project: project).path) {
                t.save(project: project)
                index.active = t.id
            }
            // Gone only once its copy is in place.
            if t.items.isEmpty || fm.fileExists(atPath: ChatTranscript.file(t.id, project: project).path) {
                try? fm.removeItem(at: legacy)
            }
        }
        let files = (try? fm.contentsOfDirectory(at: ChatTranscript.folder(project), includingPropertiesForKeys: nil)) ?? []
        let ids = Set(files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "index.json" }
            .map { $0.deletingPathExtension().lastPathComponent })
        let before = index
        index.chats.removeAll { !ids.contains($0.id) }
        for id in ids.subtracting(index.chats.map(\.id)) {
            // Listed under the file's name, whatever id is written inside it.
            if var t = ChatTranscript.load(id, project: project) { t.id = id; index.chats.append(t.summary) }
        }
        index.chats.sort { $0.date > $1.date }
        if let a = index.active, !ids.contains(a) { index.active = nil }
        if index != before { index.save(project: project) }
        return index
    }

    public func save(project: URL) { try? JSONFile.write(self, to: Self.url(project), encoder: JSONEncoder()) }

    /// Puts `s` in the list (replacing its earlier entry), newest first.
    public mutating func note(_ s: ChatTranscript.Summary) {
        chats.removeAll { $0.id == s.id }
        chats.append(s)
        chats.sort { $0.date > $1.date }
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
        var direction: [ChatChoice.Stage]?
        var web: Bool?
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

    /// The direction stages the AI asks about before building a new scene (Settings ▸ AI ▸ Chat). All by default.
    public static var directionStages: [ChatChoice.Stage] {
        get { (read().direction ?? ChatChoice.Stage.direction).filter(ChatChoice.Stage.direction.contains) }
        set { update { $0.direction = ChatChoice.Stage.direction.filter(newValue.contains) } }
    }

    /// Web search and page reading in the chat (Anthropic's server tools, about 1 cent a search). On by default.
    public static var webSearch: Bool {
        get { read().web ?? true }
        set { update { $0.web = newValue } }
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
