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
    /// Files waiting to go with the next message.
    @Published private(set) var pending: [ChatAttachment] = []
    /// Bumped whenever the transcript grows or a row changes (the view follows the bottom on it).
    @Published private(set) var revision = 0

    let project: URL
    /// What the editor shows right now, put at the start of each message (`EditorDocument.chatNote`).
    var note: () -> String? = { nil }

    private var tools: MCPStdioClient?
    private var backend: ChatBackend?
    /// The settings `backend` was made with; a change makes a new one on the next send.
    private var backendConfig = ""
    private var lastKind: ChatBackendKind?
    private var task: Task<Void, Never>?
    /// Events from the running turn, applied to the transcript a frame at a time rather than one by one (a fast
    /// stream sends hundreds a second).
    private let inbox = EventInbox()

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

    var canSend: Bool {
        hasCredentials && !running
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty)
    }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let files = pending
        draft = ""
        pending = []
        noteBackendSwitch()
        // Typed while a question waits: that's the answer, in the user's own words.
        let waiting = transcript.pendingChoice
        transcript.items.append(ChatItem(kind: .user, text: text, attachments: files.isEmpty ? nil : files))
        if let c = waiting {
            let a = ChatChoice.Answer(comment: text, typed: true)
            transcript.answer(c.id, a)
            run(c.resultText(a), attachments: files)
        } else {
            run(text, attachments: files)
        }
    }

    // MARK: Attachments

    /// Most files one message takes.
    static let maxAttachments = 10

    /// Adds files (picked, dropped or pasted). Ones that can't be attached say why in the chat.
    func attach(files urls: [URL]) {
        for u in urls { add { try ChatAttachment.store(file: u, project: project) } }
    }

    /// Adds a pasted image (PNG bytes).
    func attach(image png: Data, name: String = "Pasted image.png") {
        add { try ChatAttachment.store(data: png, name: name, project: project) }
    }

    func remove(_ a: ChatAttachment) {
        pending.removeAll { $0.id == a.id }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: a.path).deletingLastPathComponent())
    }

    private func add(_ make: () throws -> ChatAttachment) {
        guard pending.count < Self.maxAttachments else {
            say("At most \(Self.maxAttachments) files per message.")
            return
        }
        do { pending.append(try make()) } catch { say("\(error)") }
    }

    private func say(_ s: String) {
        transcript.items.append(ChatItem(kind: .error, text: s))
        revision += 1
    }

    /// The user answered a choice card.
    func answer(_ choice: ChatChoice, picked: [String], comment: String) {
        guard !running, transcript.pendingChoice?.id == choice.id else { return }
        noteBackendSwitch()
        let a = ChatChoice.Answer(picked: picked, comment: comment)
        transcript.answer(choice.id, a)
        run(choice.resultText(a))
    }

    private func noteBackendSwitch() {
        if let lastKind, lastKind != kind, !transcript.items.isEmpty {
            transcript.items.append(
                ChatItem(kind: .notice, text: "Switched how the chat runs: the AI doesn't see the messages above."))
        }
        lastKind = kind
    }

    private func run(_ text: String, attachments: [ChatAttachment] = []) {
        running = true
        revision += 1
        let context = [note(), ChatPrompt.directionNote(ChatSettings.directionStages)].compactMap { $0 }
            .joined(separator: "\n")
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
                let inbox = self.inbox
                try await b.send(text, attachments: attachments, context: context) { [weak self] e in
                    if inbox.post(e) { DispatchQueue.main.asyncAfter(deadline: .now() + 1 / 30) { self?.drain() } }
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
        ChatAttachment.prune(project: project, keep: pending)
        revision += 1
    }

    /// Applies the events that arrived since the last frame, in one change.
    private func drain() {
        let events = inbox.take()
        guard !events.isEmpty else { return }
        var t = transcript
        for e in events { t.apply(e) }
        transcript = t
        revision += 1
    }

    // MARK: Turn

    private func finish(_ error: Error?) {
        DispatchQueue.main.async { [self] in
            drain()
            transcript.endThinking()
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
            revision += 1
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
                executable: exe, model: setup.model, effort: setup.effort, projectPath: path,
                serverCommand: MCPSetup.executable,
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

/// Events posted from the turn's task, taken on the main thread.
private final class EventInbox: @unchecked Sendable {
    private var events: [ChatEvent] = []
    private let lock = NSLock()

    /// Adds one; true when it is the first since the last `take` (the caller schedules the drain).
    func post(_ e: ChatEvent) -> Bool {
        lock.withLock {
            events.append(e)
            return events.count == 1
        }
    }

    func take() -> [ChatEvent] {
        lock.withLock {
            defer { events = [] }
            return events
        }
    }
}
