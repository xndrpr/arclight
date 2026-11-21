import Foundation

/// EXPERIMENTAL, off unless `ChatSettings.cliAllowed()`. Runs each chat turn through the user's own installed
/// command-line coding agent in print mode, with Arclight's MCP server attached and every other tool turned off.
/// It uses that agent's own login; nothing here handles credentials.
public final class CLIChatBackend: ChatBackend, @unchecked Sendable {
    public var history: [JSONValue] { [] }
    public private(set) var cliSession: String?

    let executable: URL
    let model: ChatModel
    let effort: ChatEffort
    let projectPath: String
    /// How the agent starts Arclight's MCP server: this binary, `mcp --project <path>`.
    let serverCommand: String
    private var process: Process?
    private let lock = NSLock()

    /// Older agents don't know `--thinking-display`; after one says so, turns run without it.
    nonisolated(unsafe) static var noThinkingDisplay = false

    public init(
        executable: URL, model: ChatModel, effort: ChatEffort = .medium, projectPath: String, serverCommand: String,
        session: String?
    ) {
        self.executable = executable
        self.model = model
        self.effort = effort
        self.projectPath = projectPath
        self.serverCommand = serverCommand
        self.cliSession = session
    }

    public func close() {
        lock.lock()
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    /// The command-line arguments for one turn (the message goes in on stdin, as one stream-json line).
    func arguments(resume: String?, newSession: String, thinkingDisplay: Bool = true) -> [String] {
        let mcp: JSONValue = [
            "mcpServers": [
                "arclight": [
                    "command": .string(serverCommand), "args": ["mcp", "--project", .string(projectPath), "--chat"],
                ]
            ]
        ]
        var a = [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--model", model.rawValue, "--effort", effort.rawValue,
            "--strict-mcp-config", "--mcp-config", ChatPrompt.compact(mcp),
            "--tools", "",
            "--allowedTools", "mcp__arclight__*",
            "--append-system-prompt", ChatPrompt.system(instructions: "", projectPath: projectPath),
        ]
        // Without it the agent's thinking arrives empty (only its signature).
        if thinkingDisplay { a += ["--thinking-display", "summarized"] }
        if let resume { a += ["--resume", resume] } else { a += ["--session-id", newSession] }
        return a
    }

    /// The user's message as the agent's stream-json input: the editor note, attachments and text as content blocks.
    static func inputLine(_ text: String, attachments: [ChatAttachment], context: String?) -> Data {
        var blocks: [JSONValue] = []
        if let context, !context.isEmpty { blocks.append(["type": "text", "text": .string(context)]) }
        blocks += ChatAttachment.contentBlocks(attachments)
        if !text.isEmpty || blocks.isEmpty { blocks.append(["type": "text", "text": .string(text)]) }
        let line: JSONValue = ["type": "user", "message": ["role": "user", "content": .array(blocks)]]
        return Data((ChatPrompt.compact(line) + "\n").utf8)
    }

    public func send(
        _ text: String, attachments: [ChatAttachment], context: String?,
        onEvent: @escaping @Sendable (ChatEvent) -> Void
    ) async throws {
        let input = Self.inputLine(text, attachments: attachments, context: context)
        do {
            try await turn(input, thinkingDisplay: !Self.noThinkingDisplay, onEvent: onEvent)
        } catch is Unsupported {
            // An older agent: say nothing to the user, just run the turn again without the flag.
            Self.noThinkingDisplay = true
            try await turn(input, thinkingDisplay: false, onEvent: onEvent)
        }
    }

    /// The agent rejected a flag before doing anything.
    private struct Unsupported: Error {}

    private func turn(
        _ message: Data, thinkingDisplay: Bool, onEvent: @escaping @Sendable (ChatEvent) -> Void
    ) async throws {
        let session = cliSession ?? UUID().uuidString.lowercased()
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments(resume: cliSession, newSession: session, thinkingDisplay: thinkingDisplay)
        p.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = CLILocator.searchPath(env["PATH"])
        p.environment = env
        let input = Pipe(), output = Pipe(), errors = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = errors
        lock.withLock { process = p }
        signal(SIGPIPE, SIG_IGN)
        try p.run()
        try? input.fileHandleForWriting.write(contentsOf: message)
        try? input.fileHandleForWriting.close()

        let stderr = LockedText()
        errors.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil } else { stderr.append(d) }
        }
        var parser = CLIStreamParser()
        try await withTaskCancellationHandler {
            for try await line in output.fileHandleForReading.bytes.lines {
                for e in parser.feed(Data(line.utf8)) { onEvent(e) }
            }
        } onCancel: { [weak p] in
            p?.terminate()
        }
        p.waitUntilExit()
        if let s = parser.sessionId { cliSession = s }
        if Task.isCancelled { throw CancellationError() }
        if let e = parser.error { throw ChatAPIError.stream(e) }
        if p.terminationStatus != 0 {
            let err = stderr.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if thinkingDisplay, !parser.started, err.contains("thinking-display") { throw Unsupported() }
            throw ChatAPIError.stream(
                err.isEmpty
                    ? "the command-line agent exited with status \(p.terminationStatus)" : String(err.suffix(500)))
        }
        if cliSession == nil { cliSession = session }
    }
}

/// Text collected from another thread.
final class LockedText: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

/// Reads the agent's `stream-json` output: text and thinking deltas, tool calls and their results, usage (each
/// request's from its stream, the turn's from the final result) and usage-limit reports.
struct CLIStreamParser {
    private(set) var sessionId: String?
    private(set) var error: String?
    /// The model the agent runs (`system`/`init`).
    private(set) var model: String?
    private var meter = UsageMeter()
    /// Anything came back from the model (so a failure isn't a rejected flag).
    private(set) var started = false
    private var toolNames: [String: String] = [:]
    /// ask_choice calls waiting for the server's check.
    private var choices: [String: [String: JSONValue]] = [:]
    /// update_plan calls: shown as the progress bar, their results hidden.
    private var plans: Set<String> = []
    static let prefix = "mcp__arclight__"

    mutating func feed(_ line: Data, now: Date = Date()) -> [ChatEvent] {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: line), let type = v["type"]?.string else {
            return []
        }
        if let s = v["session_id"]?.string { sessionId = s }
        if type != "system" { started = true }
        switch type {
        case "system":
            if v["subtype"]?.string == "init", let m = v["model"]?.string { model = m }
            // Thinking without its text (an agent that doesn't send summaries): still show that it's thinking.
            return v["subtype"]?.string == "thinking_tokens" ? [.thinking("")] : []
        case "rate_limit_event":
            return v["rate_limit_info"].flatMap { ChatLimits(cli: $0, now: now) }.map { [.limits($0)] } ?? []
        case "stream_event":
            guard let ev = v["event"] else { return [] }
            // The agent's own requests, as the API streamed them (a subagent's are counted in the turn's result).
            if v["parent_tool_use_id"]?.string == nil {
                switch ev["type"]?.string {
                case "message_start":
                    let unfinished = takeUsage()
                    meter.feed(ev)
                    return unfinished
                case "message_delta":
                    meter.feed(ev)
                    return []
                case "message_stop":
                    return takeUsage()
                default:
                    break
                }
            }
            if ev["type"]?.string == "content_block_start", ev["content_block"]?["type"]?.string == "thinking" {
                return [.thinking("")]
            }
            guard ev["type"]?.string == "content_block_delta", let d = ev["delta"] else {
                return []
            }
            switch d["type"]?.string {
            case "text_delta": return (d["text"]?.string).map { [.text($0)] } ?? []
            case "thinking_delta":
                return (d["thinking"]?.string).flatMap { $0.isEmpty ? nil : [.thinking($0)] } ?? []
            default: return []
            }
        case "assistant":
            return (v["message"]?["content"]?.array ?? []).compactMap { b in
                guard b["type"]?.string == "tool_use", let id = b["id"]?.string else { return nil }
                var name = b["name"]?.string ?? ""
                if name.hasPrefix(Self.prefix) { name = String(name.dropFirst(Self.prefix.count)) }
                toolNames[id] = name
                if name == ChatPlan.toolName {
                    plans.insert(id)
                    if let p = try? ChatPlan.parse(b["input"]?.object ?? [:]) { return .plan(p) }
                    return nil
                }
                if name == ChatChoice.toolName {
                    // Shown as a card once the server accepts it (its result); a rejected one shows as a failed call.
                    choices[id] = b["input"]?.object ?? [:]
                    return nil
                }
                return .toolStart(id: id, name: name, input: ChatPrompt.compact(b["input"] ?? [:]))
            }
        case "user":
            return (v["message"]?["content"]?.array ?? []).flatMap { b -> [ChatEvent] in
                guard b["type"]?.string == "tool_result", let id = b["tool_use_id"]?.string else { return [] }
                if plans.remove(id) != nil { return [] }
                if let input = choices.removeValue(forKey: id) {
                    let ok = !(b["is_error"]?.bool ?? false)
                    if ok, let c = try? ChatChoice.parse(id: id, input: input) { return [.choice(c)] }
                    let why = b["content"]?.string ?? ChatPrompt.summary(b["content"]?.array ?? [])
                    return [
                        .toolStart(id: id, name: ChatChoice.toolName, input: ChatPrompt.compact(.object(input))),
                        .toolEnd(id: id, ok: false, summary: why, image: nil),
                    ]
                }
                let content: [JSONValue]
                if let s = b["content"]?.string {
                    content = [["type": "text", "text": .string(s)]]
                } else {
                    content = (b["content"]?.array ?? []).map { c in
                        // Images come back in API form here; the chat row wants the MCP form's bytes.
                        guard c["type"]?.string == "image", let src = c["source"] else { return c }
                        return ["type": "image", "data": src["data"] ?? "", "mimeType": src["media_type"] ?? ""]
                    }
                }
                let ok = !(b["is_error"]?.bool ?? false)
                return [
                    .toolEnd(
                        id: id, ok: ok, summary: ChatPrompt.summary(content), image: ChatPrompt.firstImage(content))
                ]
            }
        case "result":
            if v["is_error"]?.bool == true {
                error = v["result"]?.string ?? (v["subtype"]?.string).map { "the agent stopped: \($0)" }
            }
            return takeUsage() + (Self.turnUsage(v, model: model).map { [.usage($0)] } ?? [])
        default:
            return []
        }
    }

    /// The last request's usage, if it hasn't been reported.
    private mutating func takeUsage() -> [ChatEvent] {
        meter.take(fallbackModel: model).map { [.usage($0)] } ?? []
    }

    /// The agent's account of the turn, from its `result`. Tokens and cost: `model_usage_since_last_result` (newer
    /// agents; this process runs one turn, so that is exactly the turn), else `usage` (the main loop's, per turn) with
    /// the cost left to `total_cost_usd`, the session's running total. Also `num_turns` (model requests),
    /// `duration_api_ms`, and the model's `contextWindow` from its per-model entry.
    static func turnUsage(_ v: JSONValue, model: String?) -> ChatUsage? {
        func int(_ x: JSONValue?) -> Int? { x?.double.map { Int($0) } }
        let since = v["model_usage_since_last_result"]?.object
        let all = v["modelUsage"]?.object
        var u = ChatUsage(scope: .turn, model: model)
        if let since {
            for (_, m) in since.sorted(by: { $0.key < $1.key }) {
                u.tokens += ChatTokens(cliModelUsage: m)
                u.webSearches += int(m["webSearchRequests"]) ?? 0
                if let c = m["costUSD"]?.double { u.cost = (u.cost ?? 0) + c }
            }
        } else if let usage = v["usage"], usage.object != nil {
            u.tokens.merge(api: usage)
            u.webSearches = int(usage["server_tool_use"]?["web_search_requests"]) ?? 0
        }
        u.sessionCost = v["total_cost_usd"]?.double
        u.requests = int(v["num_turns"])
        u.modelTime = v["duration_api_ms"]?.double.map { $0 / 1000 }
        if let main = mainModel(since ?? [:], model: model) ?? mainModel(all ?? [:], model: model) {
            if u.model == nil { u.model = main.id }
            u.contextWindow = int(main.usage["contextWindow"])
        }
        guard !u.tokens.isEmpty || u.cost != nil || u.sessionCost != nil || u.requests != nil else { return nil }
        return u
    }

    /// The entry of `model` in a per-model usage table (keys may carry a suffix such as `[1m]`), else the one that
    /// wrote the most.
    static func mainModel(_ entries: [String: JSONValue], model: String?) -> (id: String, usage: JSONValue)? {
        let hit =
            model.flatMap { m in entries[m].map { (m, $0) } ?? entries.first { $0.key.hasPrefix(m) } }
            ?? entries.max { ($0.value["outputTokens"]?.double ?? 0) < ($1.value["outputTokens"]?.double ?? 0) }
        return hit.map { (id: $0.0, usage: $0.1) }
    }
}

/// Finds the user's command-line agent. Apps opened from the Finder don't get the shell's PATH, so the usual install
/// folders are checked first, then a login shell is asked.
public enum CLILocator {
    public static let name = "claude"

    static func searchPath(_ existing: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "\(home)/.claude/local", "/opt/homebrew/bin", "/usr/local/bin"]
        return (extra + (existing ?? "/usr/bin:/bin").split(separator: ":").map(String.init)).joined(separator: ":")
    }

    /// The agent's path: `custom` when it is executable, else the first one found. Blocks (it may start a shell).
    public static func locate(custom: String) -> URL? {
        let fm = FileManager.default
        let c = (custom as NSString).expandingTildeInPath
        if !c.isEmpty { return fm.isExecutableFile(atPath: c) ? URL(fileURLWithPath: c) : nil }
        for dir in searchPath(nil).split(separator: ":") {
            let p = "\(dir)/\(name)"
            if fm.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        let out = run(URL(fileURLWithPath: "/bin/zsh"), ["-lc", "command -v \(name)"])
        return out.flatMap { fm.isExecutableFile(atPath: $0) ? URL(fileURLWithPath: $0) : nil }
    }

    /// `claude --version`, for Settings. Blocks.
    public static func version(_ exe: URL) -> String? { run(exe, ["--version"]) }

    private static func run(_ exe: URL, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !s.isEmpty ? s.split(separator: "\n").last.map(String.init) : nil
    }
}
