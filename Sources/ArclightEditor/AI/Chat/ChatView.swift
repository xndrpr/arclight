import AppKit
import ArclightCore
import SwiftUI

/// The AI panel's Chat tab: talk to the AI in the editor, no outside agent needed. Its changes land in the
/// Activity tab like any agent's, with revert.
struct ChatView: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var chat: ChatController

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            if chat.transcript.items.isEmpty {
                ChatEmptyState(chat: chat).frame(maxHeight: .infinity, alignment: .top)
            } else {
                messages
            }
            Hairline()
            ChatInput(chat: chat)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // A key saved or the backend switched in Settings: redraw (status line, empty state, field).
        .onReceive(NotificationCenter.default.publisher(for: ChatSettingsChange.name)) { _ in
            chat.objectWillChange.send()
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold)).foregroundStyle(UI.ai)
            Text(chat.statusLine).font(UI.small).foregroundStyle(UI.label2).lineLimit(1)
            if chat.kind == .cli {
                Text("Experimental · CLI").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(UI.warning)
                    .padding(.horizontal, 5).frame(height: 15)
                    .background(Capsule().fill(UI.warning.opacity(0.14)))
                    .help("Runs through your own installed command-line agent and its login. Experimental.")
            }
            Spacer()
            IconButton(symbol: "square.and.pencil", help: "New chat") { chat.newChat() }
                .disabled(chat.transcript.items.isEmpty)
            IconButton(symbol: "gearshape", help: "Chat settings") { ChatSettingsLink.open() }
        }
        .padding(.horizontal, 10).frame(height: 32)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(chat.transcript.items) { ChatRow(item: $0).id($0.id) }
                    if chat.running { ChatWorking().id("working") }
                }
                .padding(12)
            }
            .onChange(of: chat.transcript.items.last?.text) { _, _ in scrollDown(proxy) }
            .onChange(of: chat.transcript.items.count) { _, _ in scrollDown(proxy) }
            .onAppear { scrollDown(proxy, animated: false) }
        }
    }

    private func scrollDown(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let id: String? = chat.running ? "working" : chat.transcript.items.last?.id
        guard let id else { return }
        if animated { withAnimation(UI.fade) { proxy.scrollTo(id, anchor: .bottom) } } else { proxy.scrollTo(id) }
    }
}

/// One chat row: the user's message, the AI's reply (Markdown), its thinking (folded), a tool call, a notice.
struct ChatRow: View {
    let item: ChatItem
    @State private var open = false

    var body: some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 30)
                Text(item.text).font(UI.font).foregroundStyle(UI.text).textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10).fill(UI.selected))
            }
        case .assistant:
            Text(Self.markdown(item.text)).font(UI.font).foregroundStyle(UI.text).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .thinking:
            fold(label: "Thinking", symbol: "brain") {
                Text(item.text).font(UI.small).foregroundStyle(UI.dim).textSelection(.enabled)
            }
        case .tool:
            ChatToolRow(item: item)
        case .notice:
            Text(item.text).font(UI.small).foregroundStyle(UI.dim).frame(maxWidth: .infinity, alignment: .leading)
        case .error:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(UI.danger)
                Text(item.text).font(UI.small).foregroundStyle(UI.text).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fold<C: View>(label: String, symbol: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withMotion(Motion.snappy) { open.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Image(systemName: symbol).font(.system(size: 9))
                    Text(label).font(UI.small)
                }
                .foregroundStyle(UI.dim).contentShape(Rectangle())
            }
            .buttonStyle(.plain).cursor(.pointingHand)
            if open { content().padding(.leading, 12).transition(.opacity) }
        }
    }

    static func markdown(_ s: String) -> AttributedString {
        (try? AttributedString(
            markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// A tool call: name, arguments at a glance, done / failed; click for its output and picture.
struct ChatToolRow: View {
    let item: ChatItem
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withMotion(Motion.snappy) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    status.frame(width: 12)
                    Text(item.tool ?? "tool").font(UI.monoSmall).foregroundStyle(UI.text)
                    Text(item.input ?? "").font(UI.monoSmall).foregroundStyle(UI.faint).lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(UI.raised))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).cursor(.pointingHand).help("Show what the tool returned")
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    if !item.text.isEmpty {
                        Text(item.text).font(UI.monoSmall).foregroundStyle(UI.label2).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let d = item.image, let img = NSImage(data: d) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(maxHeight: 160)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
                .padding(.leading, 20).transition(.opacity)
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch item.ok {
        case nil: ProgressView().controlSize(.mini)
        case true?: Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(UI.success)
        case false?: Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(UI.danger)
        }
    }
}

/// Shown under the last row while a turn runs.
private struct ChatWorking: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text("Working…").font(UI.small).foregroundStyle(UI.dim)
        }
    }
}

/// No messages yet: how to start, or what's missing.
private struct ChatEmptyState: View {
    @ObservedObject var chat: ChatController
    static let examples = [
        "Make a 5-second title card that says “Launch day”.",
        "Make the selected text bigger and slow down its reveal.",
        "Make a YouTube thumbnail for this episode with two A/B variants.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if chat.hasCredentials {
                Text(
                    "Ask the AI to build or change anything in this project. You'll see each change live, and can revert it in Activity."
                )
                .font(UI.small).foregroundStyle(UI.dim).fixedSize(horizontal: false, vertical: true)
                ForEach(Self.examples, id: \.self) { s in
                    Button {
                        chat.draft = s
                    } label: {
                        Text(s).font(UI.small).foregroundStyle(UI.label2).multilineTextAlignment(.leading)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(UI.raised))
                    }
                    .buttonStyle(.plain).cursor(.pointingHand)
                }
            } else {
                Text("To chat here, add an API key from your AI provider in Settings. It stays in your Keychain.")
                    .font(UI.small).foregroundStyle(UI.dim).fixedSize(horizontal: false, vertical: true)
                Button("Open AI settings") { ChatSettingsLink.open() }.buttonStyle(PillButtonStyle(primary: true))
            }
        }
        .padding(12)
    }
}

enum ChatSettingsLink {
    static func open() { (NSApp.delegate as? AppDelegate)?.showSettings(tab: "AI") }
}
