import Foundation

/// One finished assistant message from the Messages API stream.
public struct StreamedMessage: Equatable, Sendable {
    /// The content blocks exactly as the API sent them (thinking blocks with their signatures), ready to be sent back.
    public var content: [JSONValue] = []
    public var stopReason: String?
    public var stopDetails: JSONValue?
    /// Ids of `tool_use` blocks whose streamed input wasn't valid JSON (cut off or malformed). Their `input` is `{}`.
    public var invalidToolInputs: Set<String> = []
}

public enum ChatAPIError: Error, CustomStringConvertible, Equatable {
    case noKey
    case badKey(String)
    case http(Int, String)
    case stream(String)
    public var description: String {
        switch self {
        case .noKey: return "No API key. Add one in Settings ▸ AI ▸ Chat."
        case .badKey(let m): return "The API key was rejected (\(m)). Check it in Settings ▸ AI ▸ Chat."
        case .http(let code, let m): return "The AI service answered \(code): \(m)"
        case .stream(let m): return "The AI service stopped the reply: \(m)"
        }
    }
    /// Overloaded or rate limited: worth trying again after a pause.
    public var retryable: Bool {
        if case .http(let c, _) = self { return c == 429 || c == 529 || c >= 500 }
        return false
    }
}

/// Builds a `StreamedMessage` from server-sent events, one `data:` payload at a time, and reports text and thinking
/// as it arrives.
public struct MessageAssembler {
    public private(set) var message = StreamedMessage()
    private var blocks: [Int: JSONValue] = [:]
    private var partialJSON: [Int: String] = [:]
    private var closed: Set<Int> = []
    public private(set) var done = false

    public init() {}

    /// Feeds one event's JSON. Returns what the UI should show now (text / thinking deltas).
    public mutating func feed(_ data: Data) throws -> ChatEvent? {
        guard let ev = try? JSONDecoder().decode(JSONValue.self, from: data), let type = ev["type"]?.string else {
            return nil
        }
        switch type {
        case "content_block_start":
            guard let i = ev["index"]?.double.map(Int.init), let b = ev["content_block"] else { return nil }
            blocks[i] = b
            // A web search or fetch finished (server tools): its results arrive whole.
            if let t = b["type"]?.string, t == "web_search_tool_result" || t == "web_fetch_tool_result",
                let id = b["tool_use_id"]?.string
            {
                return Self.serverResult(id: id, block: b)
            }
        case "content_block_delta":
            guard let i = ev["index"]?.double.map(Int.init), let d = ev["delta"], var b = blocks[i]?.object else {
                return nil
            }
            switch d["type"]?.string {
            case "text_delta":
                let t = d["text"]?.string ?? ""
                b["text"] = .string((b["text"]?.string ?? "") + t)
                blocks[i] = .object(b)
                return t.isEmpty ? nil : .text(t)
            case "thinking_delta":
                let t = d["thinking"]?.string ?? ""
                b["thinking"] = .string((b["thinking"]?.string ?? "") + t)
                blocks[i] = .object(b)
                return t.isEmpty ? nil : .thinking(t)
            case "signature_delta":
                b["signature"] = .string((b["signature"]?.string ?? "") + (d["signature"]?.string ?? ""))
                blocks[i] = .object(b)
            case "input_json_delta":
                partialJSON[i, default: ""] += d["partial_json"]?.string ?? ""
            default:
                break
            }
        case "content_block_stop":
            guard let i = ev["index"]?.double.map(Int.init) else { return nil }
            finish(i)
            // A server tool (web search, fetch, the code that filters results) is starting: show it like a tool call.
            if let b = blocks[i], b["type"]?.string == "server_tool_use", let id = b["id"]?.string {
                return .toolStart(
                    id: id, name: b["name"]?.string ?? "server_tool", input: ChatPrompt.compact(b["input"] ?? [:]))
            }
        case "message_delta":
            if let r = ev["delta"]?["stop_reason"]?.string { message.stopReason = r }
            if let sd = ev["delta"]?["stop_details"], sd != .null { message.stopDetails = sd }
        case "message_stop":
            for i in blocks.keys.sorted() where !closed.contains(i) { finish(i) }
            done = true
        case "error":
            throw ChatAPIError.stream(ev["error"]?["message"]?.string ?? "unknown error")
        default:
            break
        }
        return nil
    }

    /// Closes block `i`: a tool call gets its parsed input. Blocks are kept in index order.
    private mutating func finish(_ i: Int) {
        guard var b = blocks[i]?.object else { return }
        closed.insert(i)
        if b["type"]?.string == "tool_use" || b["type"]?.string == "server_tool_use" {
            let raw = partialJSON[i] ?? ""
            if raw.isEmpty {
                if b["input"] == nil { b["input"] = [:] }
            } else if let v = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)), v.object != nil {
                b["input"] = v
            } else {
                b["input"] = [:]
                message.invalidToolInputs.insert(b["id"]?.string ?? "")
            }
        }
        blocks[i] = .object(b)
        message.content = blocks.keys.sorted().compactMap { blocks[$0] }
    }
}

extension MessageAssembler {
    /// A web search / fetch result as a finished tool row: the pages found, or the error.
    static func serverResult(id: String, block b: JSONValue) -> ChatEvent {
        let c = b["content"]
        if let err = c?["error_code"]?.string {
            return .toolEnd(id: id, ok: false, summary: "failed: \(err)", image: nil)
        }
        if let list = c?.array {
            let lines = list.prefix(8).compactMap { r -> String? in
                guard let url = r["url"]?.string else { return nil }
                return (r["title"]?.string.map { "\($0) — " } ?? "") + url
            }
            return .toolEnd(
                id: id, ok: true, summary: lines.isEmpty ? "no results" : lines.joined(separator: "\n"), image: nil)
        }
        let url = c?["url"]?.string ?? c?["content"]?["source"]?["url"]?.string
        return .toolEnd(id: id, ok: true, summary: url.map { "read \($0)" } ?? "read the page", image: nil)
    }
}

/// Streams one Messages API request. A protocol so the chat engine can be tested without the network.
public protocol MessageStreaming: Sendable {
    func stream(
        _ body: JSONValue, beta: [String], onEvent: @escaping @Sendable (ChatEvent) -> Void
    ) async throws
        -> StreamedMessage
}

/// The Messages API over HTTPS (server-sent events), with the user's API key.
public struct MessagesAPIClient: MessageStreaming {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = "2026-10-21"

    let key: String
    let session: URLSession

    public init(key: String, session: URLSession = .shared) {
        self.key = key
        self.session = session
    }

    public func stream(
        _ body: JSONValue, beta: [String], onEvent: @escaping @Sendable (ChatEvent) -> Void
    )
        async throws -> StreamedMessage
    {
        var req = URLRequest(url: Self.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if !beta.isEmpty { req.setValue(beta.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        req.httpBody = try enc.encode(body)

        let (bytes, response) = try await session.bytes(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var raw = Data()
            for try await b in bytes { raw.append(b) }
            let v = try? JSONDecoder().decode(JSONValue.self, from: raw)
            let msg = v?["error"]?["message"]?.string ?? String(decoding: raw.prefix(300), as: UTF8.self)
            if status == 401 || status == 403 { throw ChatAPIError.badKey(msg) }
            throw ChatAPIError.http(status, msg)
        }
        var asm = MessageAssembler()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).drop(while: { $0 == " " })
            if let e = try asm.feed(Data(payload.utf8)) { onEvent(e) }
            if asm.done { break }
        }
        guard asm.done else { throw ChatAPIError.stream("the connection closed before the reply finished") }
        return asm.message
    }
}
