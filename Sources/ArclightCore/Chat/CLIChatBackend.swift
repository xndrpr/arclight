import Foundation

/// EXPERIMENTAL, off unless `ChatSettings.cliAllowed()`. Runs each chat turn through the user's own installed
/// command-line coding agent in print mode, with Arclight's MCP server attached and every other tool turned off.
/// It uses that agent's own login; nothing here handles credentials.
public final class CLIChatBackend: ChatBackend, @unchecked Sendable {
    public var history: [JSONValue] { [] }
    public private(set) var cliSession: String?

    let executable: URL
    let model: ChatModel
    let projectPath: String
    /// How the agent starts Arclight's MCP server: this binary, `mcp --project <path>`.
    let serverCommand: String
    private var process: Process?
    private let lock = NSLock()

    public init(executable: URL, model: ChatModel, projectPath: String, serverCommand: String, session: String?) {
        self.executable = executable
        self.model = model
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

    /// The command-line arguments for one turn (the prompt goes in on stdin).
    func arguments(resume: String?, newSession: String) -> [String] {
        let mcp: JSONValue = [
            "mcpServers": [
                "arclight": [
                    "command": .string(serverCommand), "args": ["mcp", "--project", .string(projectPath), "--chat"],
                ]
            ]
        ]
        var a = [
            "-p", "--input-format", "text", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--model", model.rawValue,
            "--strict-mcp-config", "--mcp-config", ChatPrompt.compact(mcp),
            "--tools", "",
            "--allowedTools", "mcp__arclight__*",
            "--append-system-prompt", ChatPrompt.system(instructions: "", projectPath: projectPath),
        ]
        if let resume { a += ["--resume", resume] } else { a += ["--session-id", newSession] }
        return a
    }

    public func send(_ text: String, context: String?, onEvent: @escaping @Sendable (ChatEvent) -> Void) async throws {
        let session = cliSession ?? UUID().uuidString.lowercased()
        let p = Process()
        p.executableURL = executable
        p.arguments = arguments(resume: cliSession, newSession: session)
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
        let prompt = [context, text].compactMap { $0 }.joined(separator: "\n\n")
        try? input.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
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

/// Reads the agent's `stream-json` output: text and thinking deltas, tool calls and their results, the final result.
struct CLIStreamParser {
    private(set) var sessionId: String?
    private(set) var error: String?
    private var toolNames: [String: String] = [:]
    /// ask_choice calls waiting for the server's check.
    private var choices: [String: [String: JSONValue]] = [:]
    static let prefix = "mcp__arclight__"

    mutating func feed(_ line: Data) -> [ChatEvent] {
        guard let v = try? JSONDecoder().decode(JSONValue.self, from: line), let type = v["type"]?.string else {
            return []
        }
        if let s = v["session_id"]?.string { sessionId = s }
        switch type {
        case "stream_event":
            guard let ev = v["event"], ev["type"]?.string == "content_block_delta", let d = ev["delta"] else {
                return []
            }
            switch d["type"]?.string {
            case "text_delta": return (d["text"]?.string).map { [.text($0)] } ?? []
            case "thinking_delta": return (d["thinking"]?.string).map { [.thinking($0)] } ?? []
            default: return []
            }
        case "assistant":
            return (v["message"]?["content"]?.array ?? []).compactMap { b in
                guard b["type"]?.string == "tool_use", let id = b["id"]?.string else { return nil }
                var name = b["name"]?.string ?? ""
                if name.hasPrefix(Self.prefix) { name = String(name.dropFirst(Self.prefix.count)) }
                toolNames[id] = name
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
            return []
        default:
            return []
        }
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
