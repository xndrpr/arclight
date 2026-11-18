import Foundation

/// A line-based connection to an MCP server (newline-delimited JSON-RPC). The real one is a child process;
/// tests use an in-memory one.
public protocol MCPTransport: AnyObject, Sendable {
    /// Called with every line the server writes (no trailing newline), on a background queue.
    func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) throws
    func send(_ line: Data)
    func close()
}

public struct MCPToolInfo: Equatable, Sendable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
}

public enum MCPClientError: Error, CustomStringConvertible {
    case closed
    case server(String)
    public var description: String {
        switch self {
        case .closed: return "the Arclight tool server stopped"
        case .server(let m): return m
        }
    }
}

/// Talks to an MCP server: `initialize`, `tools/list`, `tools/call`. Thread-safe; requests may overlap.
public final class MCPStdioClient: @unchecked Sendable {
    public private(set) var tools: [MCPToolInfo] = []
    /// The server's `instructions` from `initialize`.
    public private(set) var instructions = ""

    private let transport: MCPTransport
    private let lock = NSLock()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var closed = false

    public init(transport: MCPTransport) { self.transport = transport }

    deinit { transport.close() }

    /// Starts the server and does the MCP handshake. `clientName` is how the editor's AI panel names this session.
    public func connect(clientName: String, version: String) async throws {
        try transport.start(
            onLine: { [weak self] in self?.received($0) },
            onClose: { [weak self] in self?.failAll() })
        let r = try await request(
            "initialize",
            [
                "protocolVersion": "2025-06-18", "capabilities": [:],
                "clientInfo": ["name": .string(clientName), "version": .string(version)],
            ])
        instructions = r["instructions"]?.string ?? ""
        notify("notifications/initialized")
        let list = try await request("tools/list", [:])
        tools = (list["tools"]?.array ?? []).compactMap { t in
            guard let name = t["name"]?.string else { return nil }
            return MCPToolInfo(
                name: name, description: t["description"]?.string ?? "",
                inputSchema: t["inputSchema"] ?? ["type": "object", "properties": [:]])
        }
    }

    /// Runs a tool. A tool that fails returns `isError: true` with its message, never throws; this throws only when
    /// the server itself is gone or answered with a protocol error.
    public func call(
        _ name: String, _ arguments: [String: JSONValue]
    ) async throws -> (
        content: [JSONValue], isError: Bool
    ) {
        let r = try await request("tools/call", ["name": .string(name), "arguments": .object(arguments)])
        return (r["content"]?.array ?? [], r["isError"]?.bool ?? false)
    }

    public func close() {
        transport.close()
        failAll()
    }

    // MARK: JSON-RPC

    /// A cancelled task stops waiting at once (`CancellationError`) and the server is told to drop the request
    /// (`notifications/cancelled`); an answer that still comes is ignored. What the tool already did stays done.
    private func request(_ method: String, _ params: [String: JSONValue]) async throws -> JSONValue {
        let id = lock.withLock { () -> Int in
            nextId += 1
            return nextId - 1
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSONValue, Error>) in
                lock.lock()
                if closed {
                    lock.unlock()
                    c.resume(throwing: MCPClientError.closed)
                    return
                }
                if Task.isCancelled {
                    lock.unlock()
                    c.resume(throwing: CancellationError())
                    return
                }
                pending[id] = c
                lock.unlock()
                write([
                    "jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": .object(params),
                ])
            }
        } onCancel: {
            lock.lock()
            let c = pending.removeValue(forKey: id)
            lock.unlock()
            guard let c else { return }
            write([
                "jsonrpc": "2.0", "method": "notifications/cancelled",
                "params": ["requestId": .number(Double(id)), "reason": "Stopped by the user"],
            ])
            c.resume(throwing: CancellationError())
        }
    }

    private func notify(_ method: String) {
        write(["jsonrpc": "2.0", "method": .string(method)])
    }

    private func write(_ v: JSONValue) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let d = try? enc.encode(v) else { return }
        transport.send(d)
    }

    private func received(_ line: Data) {
        guard let msg = try? JSONDecoder().decode(JSONValue.self, from: line), let id = msg["id"]?.double else {
            return
        }
        lock.lock()
        let c = pending.removeValue(forKey: Int(id))
        lock.unlock()
        guard let c else { return }
        if let err = msg["error"] {
            c.resume(throwing: MCPClientError.server(err["message"]?.string ?? "tool server error"))
        } else {
            c.resume(returning: msg["result"] ?? .null)
        }
    }

    private func failAll() {
        lock.lock()
        closed = true
        let all = pending.values
        pending.removeAll()
        lock.unlock()
        for c in all { c.resume(throwing: MCPClientError.closed) }
    }
}

/// Runs an MCP server as a child process and speaks to it over its stdin/stdout. Its stderr is discarded.
public final class ProcessTransport: MCPTransport, @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe()
    private var buffer = Data()
    private let lock = NSLock()

    public init(executable: URL, arguments: [String], environment: [String: String]? = nil) {
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
    }

    public func start(onLine: @escaping @Sendable (Data) -> Void, onClose: @escaping @Sendable () -> Void) throws {
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard let self else { return }
            if chunk.isEmpty {
                h.readabilityHandler = nil
                onClose()
                return
            }
            for line in self.lines(appending: chunk) { onLine(line) }
        }
        process.terminationHandler = { _ in onClose() }
        // A write to a server that just exited must fail, not kill the editor.
        signal(SIGPIPE, SIG_IGN)
        try process.run()
    }

    /// Splits off every complete line; keeps the rest for the next chunk.
    private func lines(appending chunk: Data) -> [Data] {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        var out: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            if !line.isEmpty { out.append(Data(line)) }
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        return out
    }

    public func send(_ line: Data) {
        guard process.isRunning else { return }
        var d = line
        d.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: d)
    }

    public func close() {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }
}
