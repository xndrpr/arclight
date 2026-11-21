import Foundation

/// Tokens one model request used, or the sum of several. In the API's words: `input_tokens` (the part of the prompt
/// not read from the cache), `output_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`.
public struct ChatTokens: Codable, Equatable, Sendable {
    public var input = 0
    public var output = 0
    public var cacheRead = 0
    public var cacheWrite = 0

    public init(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
    }

    /// The whole prompt the model read: the uncached part plus what came from the cache and went into it.
    public var prompt: Int { input + cacheRead + cacheWrite }
    public var total: Int { prompt + output }
    public var isEmpty: Bool { total == 0 }

    public static func + (a: ChatTokens, b: ChatTokens) -> ChatTokens {
        ChatTokens(
            input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
            cacheWrite: a.cacheWrite + b.cacheWrite)
    }

    public static func += (a: inout ChatTokens, b: ChatTokens) { a = a + b }

    /// Takes the counts an API-shaped `usage` object has; ones it lacks stay as they are (a `message_delta` may carry
    /// only some, and its counts are running totals for the response, so they replace rather than add).
    mutating func merge(api u: JSONValue) {
        func n(_ k: String) -> Int? { u[k]?.double.map { Int($0) } }
        if let v = n("input_tokens") { input = v }
        if let v = n("output_tokens") { output = v }
        if let v = n("cache_read_input_tokens") { cacheRead = v }
        if let v = n("cache_creation_input_tokens") { cacheWrite = v }
    }

    /// From one entry of the command-line agent's per-model usage (`modelUsage`: `inputTokens`, `outputTokens`,
    /// `cacheReadInputTokens`, `cacheCreationInputTokens`).
    init(cliModelUsage m: JSONValue) {
        func n(_ k: String) -> Int { m[k]?.double.map { Int($0) } ?? 0 }
        self.init(
            input: n("inputTokens"), output: n("outputTokens"), cacheRead: n("cacheReadInputTokens"),
            cacheWrite: n("cacheCreationInputTokens"))
    }

    enum CodingKeys: String, CodingKey { case input, output, cacheRead, cacheWrite }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
        cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheRead) ?? 0
        cacheWrite = try c.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
    }
}

/// What a backend reports about a turn's tokens and cost (`ChatEvent.usage`).
public struct ChatUsage: Equatable, Sendable {
    public enum Scope: Sendable {
        /// One model request (a round of the tool loop): added to the turn, and its prompt is how full the context is.
        case request
        /// The backend's own account of the whole turn (the command-line agent's `result`): it replaces what the turn's
        /// requests added up to.
        case turn
    }

    public var scope: Scope
    /// The provider's model id, as the backend reported it.
    public var model: String?
    public var tokens: ChatTokens
    public var webSearches: Int
    /// US dollars, when known. API: estimated from the price list (`ChatPricing`). Command-line agent: its own
    /// estimate, on the turn's account only.
    public var cost: Double?
    /// Turn scope: how many model requests the turn made (the agent's `num_turns`).
    public var requests: Int?
    /// Seconds the model spent answering: this request, or (turn scope) all of the turn's (`duration_api_ms`).
    public var modelTime: Double?
    /// The model's context window in tokens, when the backend says (the agent's `modelUsage[…].contextWindow`).
    public var contextWindow: Int?
    /// Turn scope, command-line agent: its running total for the session (`total_cost_usd`). Older agents don't say
    /// what one turn cost; the difference from the previous turn's total does.
    public var sessionCost: Double?

    public init(
        scope: Scope, model: String? = nil, tokens: ChatTokens = ChatTokens(), webSearches: Int = 0,
        cost: Double? = nil, requests: Int? = nil, modelTime: Double? = nil, contextWindow: Int? = nil,
        sessionCost: Double? = nil
    ) {
        self.scope = scope; self.model = model; self.tokens = tokens; self.webSearches = webSearches
        self.cost = cost; self.requests = requests; self.modelTime = modelTime; self.contextWindow = contextWindow
        self.sessionCost = sessionCost
    }
}

/// One turn of a chat: from the user's message (or their answer to a choice card) to the end of the reply. Kept in
/// `ChatTranscript.turns`, in order; a turn whose row was taken out ("Edit from here") stays there, so the totals
/// still count what it used.
public struct ChatTurn: Codable, Equatable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Sendable { case done, stopped, failed }

    public var id: String
    /// The row the turn answers: the user's message, or the choice card they answered.
    public var item: String?
    public var backend: ChatBackendKind?
    /// The model that answered (the backend's report of it; before that, the one asked for).
    public var model: String?
    public var started: Date
    /// When the reply ended; nil while it runs.
    public var finished: Date?
    public var outcome: Outcome?
    public var tokens = ChatTokens()
    public var webSearches = 0
    /// US dollars, when known (an estimate either way: see `ChatUsage.cost`).
    public var cost: Double?
    /// Model requests the turn made, and tool calls it ran (as shown in the chat; web searches included).
    public var requests = 0
    public var tools = 0
    /// Seconds the model spent answering, all requests together (the rest of `duration` is tools and waiting).
    public var modelTime: Double?
    /// The prompt of the turn's last request, in tokens: how full the context is after it.
    public var context: Int?
    public var contextWindow: Int?
    /// Command-line agent: its running cost total for the session at the end of this turn.
    public var sessionCost: Double?

    public init(
        id: String = UUID().uuidString, item: String?, backend: ChatBackendKind?, model: String?, started: Date
    ) {
        self.id = id; self.item = item; self.backend = backend; self.model = model; self.started = started
    }

    /// Seconds from the message to the end of the reply (nil while it runs).
    public var duration: Double? { finished.map { max(0, $0.timeIntervalSince(started)) } }
    public var running: Bool { finished == nil }

    /// Folds one usage report in (see `ChatUsage.Scope`).
    mutating func add(_ u: ChatUsage) {
        if let m = u.model { model = m }
        if let w = u.contextWindow { contextWindow = w }
        switch u.scope {
        case .request:
            tokens += u.tokens
            webSearches += u.webSearches
            requests += 1
            if let c = u.cost { cost = (cost ?? 0) + c }
            if let t = u.modelTime { modelTime = (modelTime ?? 0) + t }
            if u.tokens.prompt > 0 { context = u.tokens.prompt }
        case .turn:
            // A run that failed to start reports zeros: what the requests added up to is better than nothing.
            if !u.tokens.isEmpty {
                tokens = u.tokens
                webSearches = u.webSearches
            }
            if let r = u.requests, r > 0 { requests = r }
            if let c = u.cost { cost = c }
            if let t = u.modelTime, t > 0 { modelTime = t }
            if let s = u.sessionCost { sessionCost = s }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, item, backend, model, started, finished, outcome, tokens, webSearches, cost, requests, tools
        case modelTime, context, contextWindow, sessionCost
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        item = try c.decodeIfPresent(String.self, forKey: .item)
        backend = try? c.decodeIfPresent(ChatBackendKind.self, forKey: .backend)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        started = try c.decodeIfPresent(Date.self, forKey: .started) ?? Date(timeIntervalSince1970: 0)
        finished = try c.decodeIfPresent(Date.self, forKey: .finished)
        outcome = try? c.decodeIfPresent(Outcome.self, forKey: .outcome)
        tokens = try c.decodeIfPresent(ChatTokens.self, forKey: .tokens) ?? ChatTokens()
        webSearches = try c.decodeIfPresent(Int.self, forKey: .webSearches) ?? 0
        cost = try c.decodeIfPresent(Double.self, forKey: .cost)
        requests = try c.decodeIfPresent(Int.self, forKey: .requests) ?? 0
        tools = try c.decodeIfPresent(Int.self, forKey: .tools) ?? 0
        modelTime = try c.decodeIfPresent(Double.self, forKey: .modelTime)
        context = try c.decodeIfPresent(Int.self, forKey: .context)
        contextWindow = try c.decodeIfPresent(Int.self, forKey: .contextWindow)
        sessionCost = try c.decodeIfPresent(Double.self, forKey: .sessionCost)
    }
}

/// How full the model's context is: "42k / 1M".
public struct ChatContext: Equatable, Sendable {
    /// Tokens in the prompt of the latest request.
    public var used: Int
    /// The model's context window, when known.
    public var window: Int?
    public var model: String?

    /// Share of the window used, 0…1 (nil without a window).
    public var fraction: Double? { window.flatMap { $0 > 0 ? Double(used) / Double($0) : nil } }
}

/// How close the account is to its usage limits, as the provider last reported them. The same shape for both
/// backends: the command-line agent's subscription windows (5-hour, weekly) or an API key's rate limits (requests and
/// tokens per minute).
public struct ChatLimits: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case allowed
        /// Past a warning threshold.
        case warning = "allowed_warning"
        /// At or past the limit: requests are refused until it resets.
        case rejected
    }

    public struct Window: Codable, Equatable, Identifiable, Sendable {
        /// The provider's name for it. Command-line agent: `five_hour`, `seven_day`, `seven_day_opus`,
        /// `seven_day_sonnet`, `seven_day_overage_included`, `overage`. API: `requests`, `tokens`, `input_tokens`,
        /// `output_tokens`.
        public var id: String
        /// Share of the window used, 0…1 (it can pass 1 when usage runs past the cap).
        public var used: Double?
        /// API: the cap and what is left of it (requests or tokens; tokens are rounded to the thousand).
        public var limit: Int?
        public var remaining: Int?
        public var resets: Date?
        public var status: Status?

        public init(
            id: String, used: Double? = nil, limit: Int? = nil, remaining: Int? = nil, resets: Date? = nil,
            status: Status? = nil
        ) {
            self.id = id; self.used = used; self.limit = limit; self.remaining = remaining; self.resets = resets
            self.status = status
        }

        /// A name for the UI.
        public var label: String {
            switch id {
            case "five_hour": return "5-hour limit"
            case "seven_day": return "Weekly limit"
            case "seven_day_opus": return "Weekly Opus limit"
            case "seven_day_sonnet": return "Weekly Sonnet limit"
            case "seven_day_overage_included": return "Weekly limit (with extra usage)"
            case "overage": return "Extra usage"
            case "requests": return "Requests per minute"
            case "tokens": return "Tokens per minute"
            case "input_tokens": return "Input tokens per minute"
            case "output_tokens": return "Output tokens per minute"
            default: return id.replacingOccurrences(of: "_", with: " ")
            }
        }
    }

    public var source: ChatBackendKind
    /// The account's state as a whole (the command-line agent's; for the API, rejected after a 429).
    public var status: Status?
    /// The window that limits right now (the agent's `rateLimitType`).
    public var limiting: String?
    /// The subscription is drawing on extra (paid) usage.
    public var usingOverage: Bool?
    public var windows: [Window]
    public var observed: Date

    public init(
        source: ChatBackendKind, status: Status? = nil, limiting: String? = nil, usingOverage: Bool? = nil,
        windows: [Window], observed: Date = Date()
    ) {
        self.source = source; self.status = status; self.limiting = limiting; self.usingOverage = usingOverage
        self.windows = windows; self.observed = observed
    }

    /// The window to show when there is room for one: the limiting one, else the fullest.
    public var headline: Window? {
        windows.first { $0.id == limiting } ?? windows.max { ($0.used ?? -1) < ($1.used ?? -1) }
    }

    public func window(_ id: String) -> Window? { windows.first { $0.id == id } }

    /// This newer report folded onto `older`: its windows replace those with the same id, the rest are kept (the agent
    /// reports a window again only when it moves). A report from the other backend replaces it all.
    public func merged(onto older: ChatLimits?) -> ChatLimits {
        guard let older, older.source == source else { return self }
        var out = self
        out.windows = older.windows.filter { w in !windows.contains { $0.id == w.id } } + windows
        if out.status == nil { out.status = older.status }
        if out.limiting == nil { out.limiting = older.limiting }
        if out.usingOverage == nil { out.usingOverage = older.usingOverage }
        return out
    }

    /// From the command-line agent's `rate_limit_event` (`rate_limit_info`: `status`, `rateLimitType`, `utilization`
    /// 0…1, `resetsAt` in Unix seconds, and on newer agents `unifiedWindows` with every window).
    init?(cli info: JSONValue, now: Date = Date()) {
        guard info.object != nil else { return nil }
        func date(_ v: JSONValue?) -> Date? {
            guard let s = v?.double, s > 0 else { return nil }
            return Date(timeIntervalSince1970: s > 1e11 ? s / 1000 : s)  // seconds; milliseconds just in case
        }
        var windows: [Window] = []
        for (id, w) in (info["unifiedWindows"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            windows.append(
                Window(
                    id: id, used: w["utilization"]?.double, resets: date(w["resetsAt"]),
                    status: w["status"]?.string.flatMap(Status.init)))
        }
        let status = info["status"]?.string.flatMap(Status.init)
        let type = info["rateLimitType"]?.string
        if let type, let i = windows.firstIndex(where: { $0.id == type }) {
            // The top-level fields describe the limiting window; they are newer than nothing, never than its own.
            if windows[i].used == nil { windows[i].used = info["utilization"]?.double }
            if windows[i].resets == nil { windows[i].resets = date(info["resetsAt"]) }
            if windows[i].status == nil { windows[i].status = status }
        } else if let type {
            windows.append(
                Window(id: type, used: info["utilization"]?.double, resets: date(info["resetsAt"]), status: status))
        }
        if let s = info["overageStatus"]?.string.flatMap(Status.init), !windows.contains(where: { $0.id == "overage" }) {
            windows.append(Window(id: "overage", resets: date(info["overageResetsAt"]), status: s))
        }
        guard status != nil || !windows.isEmpty else { return nil }
        self.init(
            source: .cli, status: status, limiting: type, usingOverage: info["isUsingOverage"]?.bool,
            windows: windows, observed: now)
    }

    /// From the Messages API's `anthropic-ratelimit-{requests,tokens,input-tokens,output-tokens}-{limit,remaining,reset}`
    /// response headers (resets in RFC 3339). Nil when the response had none.
    public init?(apiHeaders: [String: String], httpStatus: Int = 200, now: Date = Date()) {
        var h: [String: String] = [:]
        for (k, v) in apiHeaders { h[k.lowercased()] = v }
        let iso = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var windows: [Window] = []
        for kind in ["requests", "tokens", "input-tokens", "output-tokens"] {
            let p = "anthropic-ratelimit-\(kind)-"
            let limit = h[p + "limit"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let remaining = h[p + "remaining"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            let resets = h[p + "reset"].flatMap { iso.date(from: $0) ?? fractional.date(from: $0) }
            guard limit != nil || remaining != nil || resets != nil else { continue }
            var used: Double?
            if let limit, let remaining, limit > 0 { used = min(1, max(0, 1 - Double(remaining) / Double(limit))) }
            windows.append(
                Window(
                    id: kind.replacingOccurrences(of: "-", with: "_"), used: used, limit: limit, remaining: remaining,
                    resets: resets))
        }
        guard !windows.isEmpty else { return nil }
        self.init(
            source: .api, status: httpStatus == 429 ? .rejected : .allowed, windows: windows, observed: now)
    }
}

/// The context window and list prices of the chat's models, for "context 42k / 1M" and the estimated cost of an API
/// turn (the command-line agent reports both itself). Prices as published for 2026-11, in US dollars per million
/// tokens; cache writes are the 5-minute kind the chat asks for (1.25 × input).
public enum ChatPricing {
    public struct Price: Equatable, Sendable {
        public var input, output, cacheRead, cacheWrite: Double
    }

    /// About a cent a web search.
    public static let webSearch = 0.01

    /// The chat model a provider id names (`claude-opus-5-5`, also with a suffix such as `[1m]` or a date).
    public static func model(_ id: String) -> ChatModel? {
        ChatModel(rawValue: id) ?? ChatModel.allCases.first { id.hasPrefix($0.rawValue) }
    }

    /// Tokens the model can read in one request.
    public static func contextWindow(_ id: String) -> Int? { model(id).map { _ in 1_000_000 } }

    /// The price for a request whose prompt is `prompt` tokens (Haiku costs more past 100K).
    public static func price(_ id: String, prompt: Int = 0) -> Price? {
        switch model(id) {
        case .opus?: return Price(input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5)
        case .sonnet?: return Price(input: 2, output: 10, cacheRead: 0.10, cacheWrite: 2.5)
        case .haiku?:
            return prompt > 100_000
                ? Price(input: 0.50, output: 2.50, cacheRead: 0.05, cacheWrite: 0.625)
                : Price(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125)
        case nil: return nil
        }
    }

    /// The estimated cost of one request, nil for a model whose price isn't known.
    public static func cost(_ id: String, tokens t: ChatTokens, webSearches: Int = 0) -> Double? {
        guard let p = price(id, prompt: t.prompt) else { return nil }
        let perToken =
            Double(t.input) * p.input + Double(t.output) * p.output + Double(t.cacheRead) * p.cacheRead
            + Double(t.cacheWrite) * p.cacheWrite
        return perToken / 1_000_000 + Double(webSearches) * webSearch
    }
}

/// One Messages API response's usage, read from its stream: `message_start` carries the model and the prompt's
/// tokens, `message_delta` the output (running totals for the response, so they replace earlier counts).
struct UsageMeter {
    private(set) var model: String?
    private(set) var tokens = ChatTokens()
    private(set) var webSearches = 0
    /// A response started and its usage hasn't been taken yet.
    private(set) var pending = false

    /// Feeds one stream event. True when it was a usage event.
    @discardableResult mutating func feed(_ ev: JSONValue) -> Bool {
        switch ev["type"]?.string {
        case "message_start":
            guard let m = ev["message"] else { return false }
            self = UsageMeter()
            model = m["model"]?.string
            if let u = m["usage"] { merge(u) }
            pending = true
            return true
        case "message_delta":
            guard let u = ev["usage"] else { return false }
            merge(u)
            pending = true
            return true
        default:
            return false
        }
    }

    /// The response's usage, once (the next call returns nil until another response starts).
    mutating func take(fallbackModel: String?) -> ChatUsage? {
        guard pending else { return nil }
        pending = false
        return ChatUsage(scope: .request, model: model ?? fallbackModel, tokens: tokens, webSearches: webSearches)
    }

    private mutating func merge(_ u: JSONValue) {
        tokens.merge(api: u)
        if let n = u["server_tool_use"]?["web_search_requests"]?.double { webSearches = Int(n) }
    }
}
