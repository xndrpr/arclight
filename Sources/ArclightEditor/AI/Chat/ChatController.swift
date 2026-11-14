import ArclightCore
import Foundation

/// The AI panel's chat for one open project: the transcript, the running turn, and the backend and tool server
/// behind it. Both backends reach Arclight's tools through a child `arclight mcp` process on this project, so every
/// change shows in the activity feed with revert, like any agent's. Touched on the main thread only (the turn itself
/// runs in a task; its events come back through the main queue, in order).
final class ChatController: ObservableObject, @unchecked Sendable {
    @Published private(set) var transcript: ChatTranscript
    @Published private(set) var running = false
    @Published var draft = ""

    let project: URL
    /// What the editor shows right now, put at the start of each message (`EditorDocument.chatNote`).
    var note: () -> String? = { nil }

    private var tools: MCPStdioClient?
    private var backend: ChatBackend?
    /// The settings `backend` was made with; a change makes a new one on the next send.
    private var backendConfig = ""
    private var lastKind: ChatBackendKind?
    private var task: Task<Void, Never>?

    init(project: URL) {
        self.project = project
        transcript = ChatTranscript.load(project: project)
    }

    deinit {
        task?.cancel()
        backend?.close()
        tools?.close()
    }

    var kind: ChatBackendKind { ChatSettings.backend }

    /// The API backend needs a key; the CLI one brings its own login.
    var hasCredentials: Bool { kind == .cli || KeychainStore.chatKey() != nil }

    var statusLine: String {
        kind == .cli ? "\(ChatSettings.model.label) · your command-line agent" : ChatSettings.model.label
    }

    // MARK: Intents

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        draft = ""
        if let lastKind, lastKind != kind, !transcript.items.isEmpty {
            transcript.items.append(
                ChatItem(kind: .notice, text: "Switched how the chat runs: the AI doesn't see the messages above."))
        }
        lastKind = kind
        transcript.items.append(ChatItem(kind: .user, text: text))
        running = true
        let context = note()
        let setup = Setup(
            kind: kind, model: ChatSettings.model, effort: ChatSettings.effort, cliPath: ChatSettings.cliPath,
            key: kind == .api ? KeychainStore.chatKey() : nil, history: transcript.history,
            session: transcript.cliSession)
        let reuse = setup.config == backendConfig ? backend : nil
        let server = tools
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let b: ChatBackend
                if let reuse { b = reuse } else { b = try await self.make(setup, server: server) }
                try await b.send(text, context: context) { [weak self] e in
                    DispatchQueue.main.async { self?.transcript.apply(e) }
                }
                self.finish(nil)
            } catch {
                self.finish(error)
            }
        }
    }

    func stop() {
        task?.cancel()
        backend?.close()  // the CLI backend's process; the API one stops with the task
    }

    func newChat() {
        stop()
        transcript = ChatTranscript()
        backend = nil
        transcript.save(project: project)
    }

    // MARK: Turn

    private func finish(_ error: Error?) {
        DispatchQueue.main.async { [self] in
            if let b = backend {
                transcript.history = b.history
                transcript.cliSession = b.cliSession
            }
            switch error {
            case nil: break
            case is CancellationError: transcript.items.append(ChatItem(kind: .notice, text: "Stopped."))
            case let e as URLError where e.code == .cancelled:
                transcript.items.append(ChatItem(kind: .notice, text: "Stopped."))
            case let e as MCPClientError:
                // The tool server went away: start a fresh one next time.
                tools = nil
                backend = nil
                transcript.items.append(ChatItem(kind: .error, text: "\(e). Send again to restart it."))
            case let e?:
                transcript.items.append(ChatItem(kind: .error, text: "\(e)"))
            }
            // A tool row left running (stopped mid-call) is shown as stopped.
            for i in transcript.items.indices where transcript.items[i].kind == .tool && transcript.items[i].ok == nil {
                transcript.items[i].ok = false
            }
            running = false
            task = nil
            transcript.save(project: project)
        }
    }

    /// What a backend is made from, read on the main thread when the user sends.
    private struct Setup {
        var kind: ChatBackendKind
        var model: ChatModel
        var effort: ChatEffort
        var cliPath: String
        var key: String?
        var history: [JSONValue]
        var session: String?
        var config: String { "\(kind)|\(model)|\(effort)|\(cliPath)|\(key?.hashValue ?? 0)" }
    }

    /// A backend for `setup`, starting the tool server if there is none. Runs in the turn's task; what it makes is
    /// kept on the main thread.
    private func make(_ setup: Setup, server: MCPStdioClient?) async throws -> ChatBackend {
        let path = project.path
        let made: ChatBackend
        switch setup.kind {
        case .api:
            guard let key = setup.key else { throw ChatAPIError.noKey }
            let runner: MCPStdioClient
            if let server { runner = server } else { runner = try await toolServer() }
            await MainActor.run { tools = runner }
            made = APIChatBackend(
                client: MessagesAPIClient(key: key), runner: runner, model: setup.model, effort: setup.effort,
                projectPath: path, history: setup.history)
        case .cli:
            guard let exe = CLILocator.locate(custom: setup.cliPath) else {
                throw ChatAPIError.stream(
                    "couldn't find the command-line agent. Set its path in Settings ▸ AI ▸ Experimental.")
            }
            made = CLIChatBackend(
                executable: exe, model: setup.model, projectPath: path, serverCommand: MCPSetup.executable,
                session: setup.session)
        }
        await MainActor.run {
            backend?.close()
            backend = made
            backendConfig = setup.config
        }
        return made
    }

    private func toolServer() async throws -> MCPStdioClient {
        let c = MCPStdioClient(
            transport: ProcessTransport(
                executable: URL(fileURLWithPath: MCPSetup.executable), arguments: ["mcp", "--project", project.path]))
        try await c.connect(clientName: "arclight-chat", version: ArclightVersion.display)
        return c
    }
}
