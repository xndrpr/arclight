import ArclightCore
import Foundation

/// Minimal MCP server: JSON-RPC 2.0, newline-delimited, over stdio. Logs go to stderr only.
public final class MCPServer {
    struct Tool {
        let name: String
        let description: String
        let schema: JSONValue
        /// Calls that never change the project; the activity log and presence show them as reads.
        var readOnly = false
        let run: ([String: JSONValue]) throws -> [JSONValue]  // MCP content blocks
    }

    var store: ProjectStore?
    private var _renderer: Renderer?
    /// Tests inject a stand-in for fal.ai here.
    var imageProviderOverride: ImageProvider?
    /// Tests point the asset library at a mock server.
    var assetLibraryOverride: AssetLibrary?
    /// Tests point the sound library at a mock server and stand in for fal.ai audio.
    var soundLibraryOverride: SoundLibrary?
    var audioProviderOverride: AudioProvider?
    var transcriptProviderOverride: TranscriptProvider?
    /// The sound rules have been shown in this session (they ride on the first sound tool's result).
    var soundBriefed = false
    var tools: [Tool] = []
    let out = FileHandle.standardOutput
    /// This session as shown in the editor's top bar and AI panel. Only written to disk while `run()` serves stdio.
    var presence = AgentPresence(pid: getpid())
    var publishesPresence = false
    var signalSources: [DispatchSourceSignal] = []
    var lastCallFailed = false

    /// `chat`: the editor's own chat started this server (through the user's command-line agent), so the chat-only
    /// `ask_choice` tool is listed too.
    public init(projectPath: String?, chat: Bool = false) {
        if let p = projectPath { store = try? ProjectStore(url: URL(expandingPath: p)) }
        tools = makeTools() + libraryTools() + themeTools() + (chat ? [chatChoiceTool(), chatPlanTool()] : [])
    }

    /// Created on first use: loading the GPU renderer is slow and most tools never need it.
    func renderer() throws -> Renderer {
        if let r = _renderer { return r }
        let r = try Renderer()
        _renderer = r
        return r
    }

    func requireStore() throws -> ProjectStore {
        guard let s = store else { throw ToolError("no project open — call project_open or project_create first") }
        try s.reload()
        return s
    }

    // MARK: Loop

    public func run() {
        startPresence()
        while let line = readLine(strippingNewline: true) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            handle(line)
        }
        Presence.remove(pid: presence.pid)  // stdin closed: the agent session ended
    }

    func handle(_ line: String) {
        guard let msg = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)), let m = msg.object else {
            send(["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "parse error"]])
            return
        }
        let id = m["id"]
        let method = m["method"]?.string ?? ""
        let params = m["params"]?.object ?? [:]
        guard let id else { return }  // notification (e.g. notifications/initialized)

        func reply(_ result: JSONValue) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
        func error(_ code: Int, _ msg: String) {
            send(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(msg)]])
        }

        switch method {
        case "initialize":
            if let info = params["clientInfo"]?.object {
                presence.client = info["name"]?.string
                presence.clientVersion = info["version"]?.string
                publishPresence()
            }
            reply([
                "protocolVersion": params["protocolVersion"] ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "arclight", "version": .string(ArclightVersion.display)],
                "instructions": .string(Guide.instructions),
            ])
        case "ping":
            reply([:])
        case "tools/list":
            reply([
                "tools": .array(
                    tools.map {
                        ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.schema]
                    })
            ])
        case "tools/call":
            let name = params["name"]?.string ?? ""
            guard let tool = tools.first(where: { $0.name == name }) else {
                error(-32602, "unknown tool '\(name)'"); return
            }
            let args = params["arguments"]?.object ?? [:]
            let sceneId = MCPServer.sceneArg(name, args)
            try? store?.reload()
            let before = sceneId.flatMap { store?.scenes[$0] }
            presence.begin(name, writes: !tool.readOnly)
            publishPresence()
            var wrote = false
            do {
                var content = try tool.run(args)
                if !soundBriefed, MCPServer.soundTools.contains(name) {
                    soundBriefed = true
                    content.append(["type": "text", "text": .string(soundBrief())])
                }
                wrote = log(name, args, sceneId: sceneId, before: before, error: nil)
                reply(["content": .array(content)])
            } catch let e {
                wrote = log(name, args, sceneId: sceneId, before: before, error: "\(e)")
                reply(["content": [["type": "text", "text": .string("\(e)")]], "isError": true])
            }
            presence.end(
                summary: MCPServer.describe(name, args), wrote: wrote, ok: !lastCallFailed,
                project: store.map { Presence.key($0.url) })
            publishPresence()
        default:
            error(-32601, "method not found: \(method)")
        }
    }

    func send(_ v: JSONValue) {
        guard var data = try? JSONFormat.wire().encode(v) else { return }
        data.append(0x0A)
        out.write(data)
    }
}
