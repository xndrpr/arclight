import ArclightCore
import Foundation

/// All the chats of one open project: the list, which one is in front, and the live `ChatController` of each chat
/// that has been opened. Chats run on their own, so one can keep working while another is in front. Main thread only.
@Observable final class ChatStore {
    let project: URL
    /// Every saved chat, newest first (plus the one in front while it is still empty).
    private(set) var list: [ChatTranscript.Summary] = []
    private(set) var activeID: String = ""
    /// What the editor shows right now, put at the start of each message.
    @ObservationIgnored var note: () -> String? = { nil }
    /// Scene revisions now, and putting scenes back to an earlier set (the document's; see `Document+Chat`).
    @ObservationIgnored var checkpoint: () -> [String: Int] = { [:] }
    @ObservationIgnored var revert: ([String: Int]) -> [String] = { _ in [] }
    @ObservationIgnored var frame: () -> URL? = { nil }

    @ObservationIgnored private var index: ChatIndex
    @ObservationIgnored private var open: [String: ChatController] = [:]

    init(project: URL) {
        self.project = project
        index = ChatIndex.load(project: project)
        let first = index.active.flatMap { id in index.chats.contains { $0.id == id } ? id : nil } ?? index.chats.first?.id
        activeID = first.map { controller($0).id } ?? adopt(ChatController(project: project)).id
        refresh()
    }

    /// The chat in front.
    var active: ChatController { controller(activeID) }

    /// The live chat with this id, read from its file the first time.
    func controller(_ id: String) -> ChatController {
        if let c = open[id] { return c }
        var t = ChatTranscript.load(id, project: project) ?? ChatTranscript()
        t.id = id
        return adopt(ChatController(project: project, transcript: t))
    }

    @discardableResult private func adopt(_ c: ChatController) -> ChatController {
        c.note = { [weak self] in self?.note() }
        c.checkpoint = { [weak self] in self?.checkpoint() ?? [:] }
        c.revert = { [weak self] in self?.revert($0) ?? [] }
        c.frame = { [weak self] in self?.frame() }
        c.onChange = { [weak self, weak c] in
            guard let self, let c else { return }
            if !c.transcript.items.isEmpty { self.index.note(c.transcript.summary) }
            self.refresh()
            self.saveIndex()
        }
        open[c.id] = c
        return c
    }

    func status(_ id: String) -> ChatController.Status { open[id]?.status ?? .idle }

    /// How many chats are working right now.
    var runningCount: Int { open.values.filter(\.running).count }

    /// The latest usage-limit report for the backend the chat in front uses. Limits belong to the account, so this
    /// is whichever open chat heard last.
    var limits: ChatLimits? {
        let kind = active.kind
        return open.values.compactMap(\.limits).filter { $0.source == kind }.max { $0.observed < $1.observed }
    }

    /// Starts an empty chat and brings it to the front (the one in front already is, when it is empty).
    func newChat() {
        if active.transcript.items.isEmpty { return }
        select(adopt(ChatController(project: project)).id)
    }

    func select(_ id: String) {
        guard id != activeID else { return }
        // An empty chat left behind was never saved: nothing to keep of it.
        if let old = open[activeID], old.transcript.items.isEmpty, !old.running { open[activeID] = nil }
        activeID = controller(id).id
        active.settingsChanged()  // Settings may have changed while it was in the back
        index.active = activeID
        refresh()
        saveIndex()
    }

    /// The chat at `offset` from the one in front in the list (⌃Tab style), wrapping.
    func step(_ offset: Int) {
        guard list.count > 1, let i = list.firstIndex(where: { $0.id == activeID }) else { return }
        select(list[((i + offset) % list.count + list.count) % list.count].id)
    }

    func rename(_ id: String, to name: String) { controller(id).rename(name) }

    /// Deletes a chat (stopping it if it is working). The newest other chat, or a new one, comes to the front.
    func delete(_ id: String) {
        if let c = open[id] { c.stop(); c.onChange = {} }
        open[id] = nil
        index.chats.removeAll { $0.id == id }
        let p = project
        // After any save of it still queued, so the file doesn't come back.
        ChatController.saver.async { ChatTranscript.delete(id, project: p) }
        if id == activeID {
            activeID = ""
            select(index.chats.first?.id ?? adopt(ChatController(project: project)).id)
        } else {
            refresh()
            saveIndex()
        }
    }

    private func refresh() {
        var l = index.chats
        if !l.contains(where: { $0.id == activeID }), let c = open[activeID] { l.insert(c.transcript.summary, at: 0) }
        if l != list { list = l }
    }

    private func saveIndex() {
        let i = index, p = project
        ChatController.saver.async { i.save(project: p) }
    }
}
