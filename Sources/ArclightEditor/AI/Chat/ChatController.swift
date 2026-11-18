import ArclightCore
import Foundation

/// One chat of an open project (`ChatStore` holds them all): the transcript, the running turn, and the backend and
/// tool server behind it. Both backends reach Arclight's tools through a child `arclight mcp` process on this project, so every
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
    /// Scene revisions now, and putting scenes back to an earlier set (set by `ChatStore`).
    var checkpoint: () -> [String: Int] = { [:] }
    var revert: ([String: Int]) -> [String] = { _ in [] }
    /// The frame the viewer shows now, as a PNG file (set by `ChatStore`): the composer's "attach this frame".
    var frame: () -> URL? = { nil }

    /// Attaches what the viewer shows right now.
    func attachFrame() {
        guard let u = frame() else { say("Couldn't render the current frame."); return }
        attach(files: [u])
        try? FileManager.default.removeItem(at: u)
    }

    /// Something the AI must be told with the next message (the user went back on its work).
    private var aside: String?

    private var tools: MCPStdioClient?
    private var backend: ChatBackend?
    /// The settings `backend` was made with; a change makes a new one on the next send.
    private var backendConfig = ""
    private var lastKind: ChatBackendKind?
    private var task: Task<Void, Never>?
    /// Events from the running turn, applied to the transcript a frame at a time rather than one by one (a fast
    /// stream sends hundreds a second).
    private let inbox = EventInbox()

    /// Called (main thread) when what the chat list shows of this chat may have changed: it started or finished
    /// a turn, or was saved.
    var onChange: () -> Void = {}

    var id: String { transcript.id }

    init(project: URL, transcript t: ChatTranscript = ChatTranscript()) {
        self.project = project
        transcript = t
        // A tool row left running by a turn that never finished (the app quit mid-call) is shown as stopped.
        for i in transcript.items.indices where transcript.items[i].kind == .tool && transcript.items[i].ok == nil {
            transcript.items[i].ok = false
        }
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
        hasCredentials && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pending.isEmpty)
    }

    /// A message written while the AI was working: sent by itself when the turn ends.
    struct Queued: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var files: [ChatAttachment]
    }

    @Published private(set) var queue: [Queued] = []
    /// True between Stop and the turn actually ending.
    @Published private(set) var stopping = false
    /// Set by "send now": the turn is being stopped so the queue goes out right after.
    private var flushAfterStop = false

    /// Sends the message in the field — or, while the AI is working, puts it in the queue.
    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }
        let files = pending
        draft = ""
        pending = []
        if running {
            queue.append(Queued(text: text, files: files))
            return
        }
        post(text, files: files)
    }

    /// Takes a queued message back into the field to change it.
    func edit(queued q: Queued) {
        guard let i = queue.firstIndex(of: q) else { return }
        queue.remove(at: i)
        draft = q.text
        pending = q.files
    }

    func remove(queued q: Queued) { queue.removeAll { $0.id == q.id } }

    /// Stops the running turn and sends the queue right away.
    func sendQueuedNow() {
        guard running, !queue.isEmpty else { return }
        flushAfterStop = true
        stop()
    }

    /// Sends the next queued message, if the chat is free to take it.
    private func sendNextQueued() {
        guard !running, !queue.isEmpty else { return }
        // Everything waiting goes as one message: the AI reads it together anyway.
        let all = queue
        queue = []
        post(all.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n"), files: all.flatMap(\.files))
    }

    private func post(_ text: String, files: [ChatAttachment]) {
        noteBackendSwitch()
        // Typed while a question waits: that's the answer, in the user's own words.
        let waiting = transcript.pendingChoice
        transcript.plan?.waiting = false
        var mine = ChatItem(kind: .user, text: text, attachments: files.isEmpty ? nil : files)
        mine.checkpoint = checkpoint()
        mine.historyCount = transcript.history.count
        transcript.items.append(mine)
        // Saved right away: a turn that never finishes (quit, crash, lost network) still keeps the message.
        persist()
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
        transcript.plan?.waiting = false
        persist()
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
        onChange()
        revision += 1
        let told = aside
        aside = nil
        let context = [
            told, note(), ChatPrompt.projectNote(ProjectNotes.read(project)),
            ChatPrompt.directionNote(ChatSettings.directionStages),
            ChatPrompt.soundNote(SoundNotes.read(project)),
        ].compactMap { $0 }
            .joined(separator: "\n")
        let setup = Setup(
            kind: kind, model: ChatSettings.model, effort: ChatSettings.effort, cliPath: ChatSettings.cliPath,
            key: kind == .api ? KeychainStore.chatKey() : nil, history: transcript.history,
            session: transcript.cliSession, web: ChatSettings.webSearch)
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
        guard running else { return }
        stopping = true
        task?.cancel()
        backend?.close()  // the CLI backend's process; the API one stops with the task
    }

    // MARK: Going back

    /// True when the message has a checkpoint to go back to (messages sent before checkpoints existed don't).
    func canGoBack(_ item: ChatItem) -> Bool { !running && item.kind == .user && item.checkpoint != nil }

    /// Puts the scenes back to where they were when `item` was sent. The conversation stays; the AI is told.
    func revertTurn(_ item: ChatItem) {
        guard canGoBack(item), let c = item.checkpoint else { return }
        let scenes = revert(c)
        let what = scenes.isEmpty ? "Nothing had changed since this message." : "Put back: \(scenes.joined(separator: ", "))."
        transcript.items.append(ChatItem(kind: .notice, text: "Reverted this turn. \(what)"))
        if !scenes.isEmpty {
            aside =
                "[The user reverted the changes made after their message “\(item.text.prefix(120))”. "
                + "Scenes put back to how they were before it: \(scenes.joined(separator: ", ")). Read a scene again before editing it.]"
        }
        revision += 1
        persist()
    }

    /// Goes back to `item`: the scenes return to where they were when it was sent, the messages from it on are
    /// taken out, and its text is back in the field to change and send again.
    func editFrom(_ item: ChatItem) {
        guard canGoBack(item), let c = item.checkpoint, let i = transcript.items.firstIndex(where: { $0.id == item.id })
        else { return }
        let scenes = revert(c)
        transcript.items.removeSubrange(i...)
        transcript.plan = nil
        queue = []
        if let n = item.historyCount, n <= transcript.history.count {
            // API: the model's own history is cut at the same point, so it never saw what followed.
            transcript.history = Array(transcript.history.prefix(n))
        }
        if transcript.cliSession != nil {
            // The command-line agent keeps its own session and can't forget: tell it what happened.
            aside =
                "[The user went back to an earlier message and rewrote it. Everything you did after that point was "
                + "undone (scenes put back: \(scenes.isEmpty ? "none" : scenes.joined(separator: ", "))). "
                + "Disregard your work after it and read scenes again before editing.]"
        }
        backend?.close()
        backend = nil  // made again from the cut history on the next send
        backendConfig = ""
        draft = item.text
        pending = item.attachments ?? []
        revision += 1
        persist()
    }

    /// Gives the chat a name of the user's own (empty: back to the first message).
    func rename(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript.name = n.isEmpty ? nil : n
        persist()
    }

    /// What the chat list shows of this chat.
    enum Status { case idle, running, waiting, failed }

    var status: Status {
        if running { return .running }
        if transcript.pendingChoice != nil { return .waiting }
        return transcript.items.last?.kind == .error ? .failed : .idle
    }

    /// What the AI is doing right now, in words (the progress bar's live line).
    var activity: String? {
        guard running else { return nil }
        if let t = transcript.items.last(where: { $0.kind == .tool && $0.ok == nil }) {
            return ChatToolNames.doing(t.tool ?? "")
        }
        switch transcript.items.last?.kind {
        case .thinking?: return "Thinking"
        case .assistant?: return "Writing"
        default: return "Working"
        }
    }

    /// Applies the events that arrived since the last frame, in one change.
    private func drain() {
        let events = inbox.take()
        guard !events.isEmpty else { return }
        var t = transcript
        for e in events { t.apply(e) }
        transcript = t
        revision += 1
        // Long turns are saved as they go (at most every few seconds).
        if Date().timeIntervalSince(lastSave) > 4 {
            lastSave = Date()
            persist()
        }
    }

    private var lastSave = Date.distantPast

    /// Saves off the main thread (a long chat's history is megabytes of JSON), in order, so a later save never
    /// loses to an earlier one.
    private func persist() {
        transcript.updated = Date()
        let t = transcript, p = project
        Self.saver.async { t.save(project: p) }
        onChange()
    }

    static let saver = DispatchQueue(label: "arclight.chat.save", qos: .utility)

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
            stopping = false
            task = nil
            revision += 1
            persist()
            // The queue goes out after a turn that ended by itself, or one stopped for it ("send now"). After a
            // plain Stop or an error it waits: the user decides.
            let flush = flushAfterStop
            flushAfterStop = false
            if error == nil || flush { sendNextQueued() }
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
        var web: Bool
        var config: String { "\(kind)|\(model)|\(effort)|\(cliPath)|\(key?.hashValue ?? 0)|\(web)" }
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
                projectPath: path, history: setup.history, web: setup.web)
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
