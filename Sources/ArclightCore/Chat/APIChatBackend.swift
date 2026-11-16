import Foundation

/// Runs chat turns. One turn at a time; the caller (the editor) never overlaps them.
public protocol ChatBackend: AnyObject {
    /// API backend: the conversation so far (save it with the transcript).
    var history: [JSONValue] { get }
    /// CLI backend: the session to resume.
    var cliSession: String? { get }
    /// Runs one user turn to the end (all its tool calls). `context` is a short note on what the editor shows now;
    /// `attachments` are files the user sent with the message.
    func send(
        _ text: String, attachments: [ChatAttachment], context: String?,
        onEvent: @escaping @Sendable (ChatEvent) -> Void) async throws
    func close()
}

extension ChatBackend {
    public func send(_ text: String, context: String?, onEvent: @escaping @Sendable (ChatEvent) -> Void) async throws {
        try await send(text, attachments: [], context: context, onEvent: onEvent)
    }
}

/// The tools a chat can call. `MCPStdioClient` is the real one.
public protocol ChatToolRunner: AnyObject, Sendable {
    var tools: [MCPToolInfo] { get }
    var instructions: String { get }
    func call(_ name: String, _ arguments: [String: JSONValue]) async throws -> (content: [JSONValue], isError: Bool)
}

extension MCPStdioClient: ChatToolRunner {}

/// The Messages API backend: a manual tool loop over Arclight's MCP tools. The history is append-only (earlier
/// messages are never edited), so thinking blocks stay valid and the prompt cache keeps hitting.
public final class APIChatBackend: ChatBackend, @unchecked Sendable {
    public private(set) var history: [JSONValue]
    public var cliSession: String? { nil }

    let client: MessageStreaming
    let runner: ChatToolRunner
    let model: ChatModel
    let effort: ChatEffort
    let system: String
    /// Tool rounds allowed in one user turn before the chat stops and asks the user.
    var maxRounds = 40
    /// Pauses before retrying an overloaded or rate-limited request (tests shorten them).
    var retryDelays: [Double] = [2, 6, 15]

    public init(
        client: MessageStreaming, runner: ChatToolRunner, model: ChatModel, effort: ChatEffort, projectPath: String,
        history: [JSONValue]
    ) {
        self.client = client
        self.runner = runner
        self.model = model
        self.effort = effort
        self.system = ChatPrompt.system(instructions: runner.instructions, projectPath: projectPath)
        self.history = history
    }

    public func close() {}

    public func send(
        _ text: String, attachments: [ChatAttachment], context: String?,
        onEvent: @escaping @Sendable (ChatEvent) -> Void
    ) async throws {
        var blocks: [JSONValue] = []
        let waiting = Self.unanswered(history)
        if let first = waiting.first {
            // The last turn stopped on ask_choice: this message is its answer, sent as the call's result.
            blocks.append(["type": "tool_result", "tool_use_id": .string(first), "content": .string(text)])
            for id in waiting.dropFirst() { blocks.append(Self.errorResult(id, "Not asked: one question at a time.")) }
            if let context, !context.isEmpty { blocks.append(["type": "text", "text": .string(context)]) }
            blocks += ChatAttachment.contentBlocks(attachments)
        } else {
            if let context, !context.isEmpty { blocks.append(["type": "text", "text": .string(context)]) }
            blocks += ChatAttachment.contentBlocks(attachments)
            if !text.isEmpty || blocks.isEmpty { blocks.append(["type": "text", "text": .string(text)]) }
        }
        appendUser(blocks)

        for _ in 0..<maxRounds {
            try Task.checkCancellation()
            let msg = try await streamWithRetry(onEvent)
            let calls = msg.content.filter { $0["type"]?.string == "tool_use" }
            switch msg.stopReason {
            case "max_tokens": onEvent(.notice("The reply was cut off (it hit the length limit)."))
            case "refusal": onEvent(.notice(ChatPrompt.declined(msg.stopDetails)))
            default: break
            }
            guard !calls.isEmpty else {
                if !msg.content.isEmpty { history.append(["role": "assistant", "content": .array(msg.content)]) }
                return
            }
            // The assistant turn and its results are appended together, so a stop never leaves a call unanswered.
            let runTools = msg.stopReason == "tool_use"
            var results: [JSONValue] = []
            var cancelled = false
            // An ask_choice call is answered by the user, on the next turn: the other calls run now.
            var asked: ChatChoice?
            for c in calls {
                let id = c["id"]?.string ?? ""
                let name = c["name"]?.string ?? ""
                let input = c["input"]?.object ?? [:]
                if name == ChatChoice.toolName, runTools, !msg.invalidToolInputs.contains(id), !cancelled {
                    if asked != nil {
                        results.append(Self.errorResult(id, "Not asked: one question at a time."))
                        continue
                    }
                    do {
                        let choice = try ChatChoice.parse(id: id, input: input)
                        asked = choice
                    } catch {
                        results.append(Self.errorResult(id, "\(error)"))
                    }
                    continue
                }
                if name == ChatPlan.toolName, runTools, !msg.invalidToolInputs.contains(id), !cancelled {
                    // The progress bar: shown at once, never a tool row.
                    do {
                        onEvent(.plan(try ChatPlan.parse(input)))
                        results.append(["type": "tool_result", "tool_use_id": .string(id), "content": .string(ChatPlan.ack)])
                    } catch {
                        results.append(Self.errorResult(id, "\(error)"))
                    }
                    continue
                }
                onEvent(.toolStart(id: id, name: name, input: ChatPrompt.compact(.object(input))))
                if cancelled || Task.isCancelled {
                    cancelled = true
                    results.append(Self.errorResult(id, "Stopped by the user before this ran."))
                    onEvent(.toolEnd(id: id, ok: false, summary: "Stopped", image: nil))
                } else if msg.invalidToolInputs.contains(id) || !runTools {
                    let why =
                        runTools
                        ? "The tool input wasn't valid JSON (it may have been cut off). Send it again, smaller if needed."
                        : "Not run: the reply ended before the call was complete."
                    results.append(Self.errorResult(id, why))
                    onEvent(.toolEnd(id: id, ok: false, summary: why, image: nil))
                } else {
                    let (r, event) = await run(id: id, name: name, input: input)
                    results.append(r)
                    onEvent(event)
                }
            }
            history.append(["role": "assistant", "content": .array(msg.content)])
            if let asked, !cancelled {
                // Stop and wait. The other results are kept; the answer joins them in the same message next turn.
                if !results.isEmpty { history.append(["role": "user", "content": .array(results)]) }
                onEvent(.choice(asked))
                return
            }
            if let asked {
                results.append(Self.errorResult(asked.id, "Stopped by the user before this ran."))
            }
            history.append(["role": "user", "content": .array(results)])
            if cancelled { throw CancellationError() }
            if !runTools { return }
        }
        onEvent(.notice("Stopped after \(maxRounds) tool rounds. Say “continue” to keep going."))
    }

    /// Adds the user's blocks: to the last message when it is already the user's (a turn that was stopped or
    /// failed after its tool results), else as a new message. The API needs user and assistant turns to alternate.
    private func appendUser(_ blocks: [JSONValue]) {
        if var last = history.last?.object, last["role"]?.string == "user" {
            var content: [JSONValue]
            if let s = last["content"]?.string {
                content = [["type": "text", "text": .string(s)]]
            } else {
                content = last["content"]?.array ?? []
            }
            content += blocks
            last["content"] = .array(content)
            history[history.count - 1] = .object(last)
        } else {
            history.append(["role": "user", "content": .array(blocks)])
        }
    }

    private func run(id: String, name: String, input: [String: JSONValue]) async -> (JSONValue, ChatEvent) {
        do {
            let (content, isError) = try await runner.call(name, input)
            let summary = ChatPrompt.summary(content)
            var r: [String: JSONValue] = [
                "type": "tool_result", "tool_use_id": .string(id), "content": .array(ChatPrompt.toolContent(content)),
            ]
            if isError { r["is_error"] = true }
            return (.object(r), .toolEnd(id: id, ok: !isError, summary: summary, image: ChatPrompt.firstImage(content)))
        } catch {
            let m = "\(error)"
            return (Self.errorResult(id, m), .toolEnd(id: id, ok: false, summary: m, image: nil))
        }
    }

    /// Ids of the last assistant turn's tool calls that have no result yet (an ask_choice waiting for the user).
    static func unanswered(_ history: [JSONValue]) -> [String] {
        guard let a = history.lastIndex(where: { $0["role"]?.string == "assistant" }) else { return [] }
        let calls = (history[a]["content"]?.array ?? []).filter { $0["type"]?.string == "tool_use" }
            .compactMap { $0["id"]?.string }
        guard !calls.isEmpty else { return [] }
        let answered = Set(
            history[(a + 1)...].flatMap { $0["content"]?.array ?? [] }
                .filter { $0["type"]?.string == "tool_result" }.compactMap { $0["tool_use_id"]?.string })
        return calls.filter { !answered.contains($0) }
    }

    static func errorResult(_ id: String, _ text: String) -> JSONValue {
        ["type": "tool_result", "tool_use_id": .string(id), "content": .string(text), "is_error": true]
    }

    private func streamWithRetry(_ onEvent: @escaping @Sendable (ChatEvent) -> Void) async throws -> StreamedMessage {
        let (body, beta) = ChatPrompt.request(
            model: model, effort: effort, system: system, tools: runner.tools, messages: history)
        var attempt = 0
        while true {
            do {
                return try await client.stream(body, beta: beta, onEvent: onEvent)
            } catch let e as ChatAPIError where e.retryable && attempt < retryDelays.count {
                onEvent(.notice("The AI service is busy — trying again…"))
                try await Task.sleep(nanoseconds: UInt64(retryDelays[attempt] * 1_000_000_000))
                attempt += 1
            }
        }
    }
}
