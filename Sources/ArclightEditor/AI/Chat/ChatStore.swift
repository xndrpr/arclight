import ArclightCore
import Foundation

/// All the chats of one open project: the list, which one is in front, and the live `ChatController` of each chat
/// that has been opened. Chats run on their own, so one can keep working while another is in front. Main thread only.
final class ChatStore: ObservableObject {
    let project: URL
    /// Every saved chat, newest first (plus the one in front while it is still empty).
    @Published private(set) var list: [ChatTranscript.Summary] = []
    @Published private(set) var activeID: String = ""
    /// What the editor shows right now, put at the start of each message.
    var note: () -> String? = { nil }
    /// Scene revisions now, and putting scenes back to an earlier set (the document's; see `Document+Chat`).
    var checkpoint: () -> [String: Int] = { [:] }
    var revert: ([String: Int]) -> [String] = { _ in [] }
    var frame: () -> URL? = { nil }
    /// Called when another chat comes to the front (the views showing "the chat" follow it).
    var onActiveChange: () -> Void = {}

    private var index: ChatIndex
    private var open: [String: ChatController] = [:]

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
        index.active = activeID
        refresh()
        saveIndex()
        onActiveChange()
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
        if l != list { list = l } else { objectWillChange.send() }  // a status may have changed
    }

    private func saveIndex() {
        let i = index, p = project
        ChatController.saver.async { i.save(project: p) }
    }
}
