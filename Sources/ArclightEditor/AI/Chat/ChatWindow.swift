import AppKit
import ArclightCore
import SwiftUI

/// A project's chats in a window of their own: the list on the left, the chat in front on the right. It shows the
/// same chats as the AI panel (one `ChatStore`), so it can sit on another screen while the editor plays.
final class ChatWindowController: NSWindowController, NSWindowDelegate {
    init(doc: EditorDocument) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered,
            defer: false)
        w.minSize = NSSize(width: 520, height: 380)
        w.title = "Chats — \(doc.project.name)"
        super.init(window: w)
        w.delegate = self
        AppWindows.configure(w, background: .panel, content: ChatWindowView(doc: doc, chats: doc.chats))
        w.titleVisibility = .visible
        w.setFrameAutosaveName("arclight.chats")
        if !w.setFrameUsingName("arclight.chats") { w.center() }
    }

    required init?(coder: NSCoder) { fatalError() }
}

extension EditorDocument {
    /// Shows the project's chats in their own window (made the first time).
    func openChatWindow() {
        if chatWindow == nil { chatWindow = ChatWindowController(doc: self) }
        chatWindow?.showWindow(nil)
        chatWindow?.window?.makeKeyAndOrderFront(nil)
    }
}

struct ChatWindowView: View {
    let doc: EditorDocument
    @ObservedObject var chats: ChatStore

    var body: some View {
        GeometryReader { g in
            // A narrow window is all chat; the list comes back when there is room for both.
            let sidebar = g.size.width >= 680
            HStack(spacing: 0) {
                if sidebar {
                    ChatSidebar(chats: chats).frame(width: 250)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    Rectangle().fill(UI.border).frame(width: 1)
                }
                ChatView(doc: doc, chat: chats.active).id(chats.activeID)
                    .transition(.opacity)
            }
            .animation(Motion.snappy, value: sidebar)
            .animation(Motion.animation(UI.fade), value: chats.activeID)
        }
        .background(UI.panel)
    }
}

/// The chat list: newest first, a dot for a chat that is working, waiting for an answer, or failed.
struct ChatSidebar: View {
    @ObservedObject var chats: ChatStore
    @State private var renaming: String?
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button {
                chats.newChat()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.pencil").font(.system(size: 11, weight: .medium))
                    Text("New chat").font(UI.font)
                    Spacer()
                    Text("⌘N").font(UI.monoSmall).foregroundStyle(UI.faint)
                }
                .foregroundStyle(UI.text).padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(UI.raised))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(UI.border))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).cursor(.pointingHand).keyboardShortcut("n", modifiers: .command)
            .padding(10)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(chats.list.enumerated()), id: \.element.id) { i, c in
                        row(c, shortcut: i < 9 ? i + 1 : nil)
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
                .animation(Motion.snappy, value: chats.list.map(\.id))
            }
        }
        .background(UI.bg)
    }

    @ViewBuilder private func row(_ c: ChatTranscript.Summary, shortcut: Int?) -> some View {
        let front = c.id == chats.activeID
        let status = chats.status(c.id)
        ChatSidebarRow(
            summary: c, front: front, status: status, renaming: renaming == c.id, name: $name,
            nameFocused: $nameFocused,
            open: { chats.select(c.id) },
            commit: {
                chats.rename(c.id, to: name)
                renaming = nil
            }
        )
        .contextMenu {
            Button("Rename") {
                name = c.title; renaming = c.id
                DispatchQueue.main.async { nameFocused = true }
            }
            Button("Delete", role: .destructive) { chats.delete(c.id) }
        }
        .background {
            // ⌘1…⌘9 bring a chat to the front.
            if let shortcut {
                Button("") { chats.select(c.id) }
                    .keyboardShortcut(KeyEquivalent(Character("\(shortcut)")), modifiers: .command)
                    .opacity(0).allowsHitTesting(false)
            }
        }
    }
}

private struct ChatSidebarRow: View {
    let summary: ChatTranscript.Summary
    let front: Bool
    let status: ChatController.Status
    let renaming: Bool
    @Binding var name: String
    var nameFocused: FocusState<Bool>.Binding
    let open: () -> Void
    let commit: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            dot.frame(width: 8).padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                if renaming {
                    TextField("Name", text: $name).textFieldStyle(.plain).font(UI.font).focused(nameFocused)
                        .onSubmit(commit)
                } else {
                    Text(summary.title).font(UI.font).foregroundStyle(front ? UI.text : UI.label2).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(caption).font(.system(size: 10.5)).foregroundStyle(status == .failed ? UI.danger : UI.faint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(front ? UI.selected : (hover ? UI.hover : .clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hover = $0 }
        .animation(UI.fade, value: front)
        .animation(UI.fade, value: hover)
    }

    private var caption: String {
        switch status {
        case .running: return "Working…"
        case .waiting: return "Waiting for your answer"
        case .failed: return "Stopped on an error"
        case .idle:
            return "\(ChatView.date(summary.date)) · \(summary.messages) message\(summary.messages == 1 ? "" : "s")"
        }
    }

    @ViewBuilder private var dot: some View {
        switch status {
        case .running: StatusDot(color: UI.ai, pulsing: true)
        case .waiting: StatusDot(color: UI.warning)
        case .failed: StatusDot(color: UI.danger)
        case .idle: StatusDot(color: front ? UI.accent : UI.faint.opacity(0.35), size: 5)
        }
    }
}
