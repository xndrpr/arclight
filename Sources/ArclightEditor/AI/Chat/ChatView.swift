import AppKit
import ArclightCore
import SwiftUI
import UniformTypeIdentifiers

/// The AI panel's Chat tab: talk to the AI in the editor, no outside agent needed. Its changes land in the
/// Activity tab like any agent's, with revert.
struct ChatView: View {
    /// Not observed: only choice cards read it (and they observe it themselves). Observing it here redrew the
    /// whole chat on every document change.
    let doc: EditorDocument
    let chat: ChatController
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ChatProgress(chat: chat).animation(UI.fade, value: chat.transcript.plan == nil && chat.activity == nil)
            if chat.transcript.items.isEmpty {
                ChatEmptyState(chat: chat).frame(maxHeight: .infinity, alignment: .top)
            } else {
                // Equatable: typing in the field (draft) or attaching files doesn't redraw the history.
                ChatMessageList(
                    doc: doc, chat: chat, items: chat.transcript.items, running: chat.running,
                    activity: chat.activity, revision: chat.revision, turns: chat.transcript.turns
                )
                .equatable()
            }
            ChatInput(chat: chat)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping) { providers in
            guard chat.hasCredentials else { return false }
            Self.load(providers) { urls, images in
                chat.attach(files: urls)
                for d in images { chat.attach(image: d) }
            }
            return true
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 8).stroke(UI.accent, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .background(RoundedRectangle(cornerRadius: 8).fill(UI.accent.opacity(0.06)))
                    .overlay(
                        Label("Drop to attach", systemImage: "paperclip").font(UI.small).foregroundStyle(UI.accent)
                    )
                    .padding(4).allowsHitTesting(false)
            }
        }
        // A key saved or the backend switched in Settings: redraw (status line, empty state, field).
        .onReceive(NotificationCenter.default.publisher(for: ChatSettingsChange.name)) { _ in chat.settingsChanged() }
    }

    /// The chat's name (opening the project's chats), its usage, then the image model, notes, new chat and settings.
    /// The chat model is in the composer, where it is picked.
    private var header: some View {
        HStack(spacing: 2) {
            ChatListMenu(chats: doc.chats)
            Spacer(minLength: 8)
            ChatUsageButton(chat: chat, chats: doc.chats)
            ChatModelMenu()
            ProjectNotesButton(project: chat.project)
            IconButton(symbol: "square.and.pencil", help: "New chat (this one stays in the list and keeps working)") {
                doc.chats.newChat()
            }
            .disabled(chat.transcript.items.isEmpty)
            IconButton(symbol: "gearshape", help: "Chat settings") { ChatSettingsLink.open() }
        }
        .padding(.leading, 8).padding(.trailing, 6).frame(height: 36)
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }

    /// Files and images dropped on the chat: file URLs, else image data as PNG.
    static func load(_ providers: [NSItemProvider], done: @escaping ([URL], [Data]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        var images: [Data] = []
        for p in providers {
            group.enter()
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { u, _ in
                    if let u { lock.withLock { urls.append(u) } }
                    group.leave()
                }
            } else {
                p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { d, _ in
                    if let d, let rep = NSBitmapImageRep(data: d),
                        let png = rep.representation(using: .png, properties: [:])
                    {
                        lock.withLock { images.append(png) }
                    }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { done(urls, images) }
    }
}

/// The message list. Lazy: only rows on screen are laid out, so a long chat stays fast while it streams.
private struct ChatMessageList: View, Equatable {
    let doc: EditorDocument
    let chat: ChatController
    let items: [ChatItem]
    let running: Bool
    let activity: String?
    let revision: Int
    let turns: [ChatTurn]
    /// The list is scrolled to (near) the bottom: new rows keep it there. Scrolling up stops following.
    @State private var pinned = true
    @State private var viewport: CGFloat = 0
    /// Where the content's top was last frame. New text grows the list downward and leaves it still; only
    /// scrolling moves it.
    @State private var scroll = ScrollMemo()
    @Environment(\.chatVisible) private var visible

    /// Not view state: it changes on every frame of a scroll and nothing is drawn from it.
    private final class ScrollMemo {
        var lastTop: CGFloat = 0
        /// When the user last scrolled down with the wheel or trackpad: only then does reaching the bottom
        /// follow it again (new text arriving at the bottom must not).
        var wheelDown: CFTimeInterval = 0
    }

    static func == (a: Self, b: Self) -> Bool {
        // `revision` moves with every change to the rows: comparing the rows themselves (megabytes of text and
        // pictures, 30 times a second) would cost more than the redraw it saves.
        a.revision == b.revision && a.running == b.running && a.activity == b.activity
            && a.items.count == b.items.count && a.chat === b.chat && a.turns.count == b.turns.count
    }

    var body: some View {
        let lastId = items.last?.id
        let lines = ChatLine.lines(items, turns: turns, running: running)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(lines) { line in
                        VStack(alignment: .leading, spacing: 8) {
                            if let d = line.day { ChatDayDivider(title: d) }
                            switch line.block {
                            case .item(let item):
                                if item.kind == .choice, let c = item.choice {
                                    ChoiceCard(doc: doc, chat: chat, choice: c)
                                } else {
                                    ChatRow(
                                        item: item, live: running && item.id == lastId, author: line.author,
                                        turn: item.kind == .assistant ? line.turn : nil,
                                        canGoBack: !running && item.checkpoint != nil,
                                        editFrom: { confirmBack(item, edit: true) },
                                        revert: { confirmBack(item, edit: false) }
                                    )
                                    .equatable()
                                }
                            case .work(let steps):
                                ChatWorkGroup(steps: steps, live: running && steps.last?.id == lastId).equatable()
                            }
                            // A reply draws its turn's line itself, next to its copy button.
                            if let t = line.turn, !line.isReply { ChatTurnFooter(turn: t) }
                        }
                    }
                    // Before the first event of a turn arrives, something must show that it started.
                    if running, case .item(let last)? = lines.last?.block, last.kind != .assistant {
                        ChatWorking(label: activity)
                    }
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                // Wide panels (expanded) keep a readable line length.
                .frame(maxWidth: 760).frame(maxWidth: .infinity)
                .background(
                    GeometryReader { g in
                        Color.clear.preference(
                            key: ChatScrollKey.self,
                            value: ChatScrollKey.Value(
                                top: g.frame(in: .named(Self.space)).minY, bottom: g.frame(in: .named(Self.space)).maxY))
                    })
            }
            .coordinateSpace(name: Self.space)
            .background(
                GeometryReader { g in
                    Color.clear.onAppear { viewport = g.size.height }.onChange(of: g.size.height) { _, h in viewport = h
                    }
                }
            )
            .onPreferenceChange(ChatScrollKey.self) { v in
                // The top moving down means the user scrolled up: stop following, even mid-stream. Back near
                // the bottom follows again. Content growing never unpins.
                // The scroller dragged up (no wheel event) also stops following. Back at the bottom follows again
                // only after the user scrolled down to it.
                if v.top > scroll.lastTop + 0.5, pinned, CACurrentMediaTime() - scroll.wheelDown > 0.3 {
                    pinned = false
                } else if !pinned, v.bottom - viewport < 24, CACurrentMediaTime() - scroll.wheelDown < 0.4 {
                    pinned = true
                }
                scroll.lastTop = v.top
            }
            .onChange(of: revision) { _, _ in
                if pinned { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .onChange(of: items.count) { old, new in
                // The user's own message always brings the list back down.
                if new > old, items.last?.kind == .user {
                    pinned = true
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                }
            }
            .onAppear { DispatchQueue.main.async { proxy.scrollTo(Self.bottom, anchor: .bottom) } }
            // A scroll up stops following at once, on the event itself: waiting for the layout to show it let
            // the next streamed words pull the list back down first.
            .background(
                ScrollWheelWatcher { up in
                    // Hidden behind the Activity tab, the feed's scrolling must not unpin the chat.
                    guard visible else { return }
                    if up {
                        if pinned { pinned = false }
                    } else {
                        scroll.wheelDown = CACurrentMediaTime()
                    }
                })
            .overlay(alignment: .bottom) {
                if !pinned {
                    Button {
                        pinned = true
                        withMotion(UI.fade) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                    } label: {
                        HStack(spacing: 5) {
                            if running {
                                ProgressView().controlSize(.mini)
                                Text("AI is writing").font(UI.small)
                            }
                            Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(UI.text).padding(.horizontal, running ? 10 : 0)
                        .frame(minWidth: 28, minHeight: 28)
                        .background(Capsule().fill(UI.raised))
                        .overlay(Capsule().stroke(UI.border))
                        .shadow(color: .black.opacity(0.22), radius: 6, y: 2)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain).cursor(.pointingHand).help("Jump to the latest (⌘↓)")
                    .keyboardShortcut(.downArrow, modifiers: .command)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    /// Going back changes scenes (and "edit" removes messages): asked first.
    private func confirmBack(_ item: ChatItem, edit: Bool) {
        let a = NSAlert()
        a.messageText = edit ? "Go back to this message?" : "Revert this turn?"
        a.informativeText =
            edit
            ? "The scenes go back to how they were when you sent it, and the messages after it are removed. Its text returns to the field so you can change it. What the AI made stays in each scene's History."
            : "The scenes go back to how they were when you sent this message. The conversation stays, and what the AI made stays in each scene's History."
        a.addButton(withTitle: edit ? "Go Back" : "Revert")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if edit { chat.editFrom(item) } else { chat.revertTurn(item) }
    }

    private static let bottom = "chat-bottom"
    private static let space = "chat-scroll"
}

/// Where the message list's content ends (in the scroll view's own space) and how tall it is.
private struct ChatScrollKey: PreferenceKey {
    struct Value: Equatable { var top: CGFloat = 0; var bottom: CGFloat = 0 }
    static let defaultValue = Value()
    static func reduce(value: inout Value, nextValue: () -> Value) { value = nextValue() }
}

/// One chat row: the user's message, the AI's reply (Markdown), its thinking (folded), a tool call, a notice.
struct ChatRow: View, Equatable {
    let item: ChatItem
    /// The row the running turn is writing to now.
    var live = false
    /// A reply that starts the turn's answer: "✦ Arclight · 14:32" above it.
    var author = false
    /// The turn this reply ends: its time, tokens and cost, drawn under it.
    var turn: ChatTurn?
    /// User rows: the message can be gone back to (it has a checkpoint and nothing is running).
    var canGoBack = false
    var editFrom: () -> Void = {}
    var revert: () -> Void = {}
    @State private var hover = false

    static func == (a: ChatRow, b: ChatRow) -> Bool {
        a.item == b.item && a.live == b.live && a.canGoBack == b.canGoBack && a.author == b.author
            && a.turn == b.turn
    }

    var body: some View {
        switch item.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if let files = item.attachments, !files.isEmpty {
                    FlowLayout(spacing: 6, alignment: .trailing) {
                        ForEach(files) { a in
                            if a.kind == .image {
                                AttachmentThumb(attachment: a, side: 72)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(UI.border))
                                    .help("\(a.name): click to open")
                                    .cursor(.pointingHand)
                                    .onClick { _ in NSWorkspace.shared.open(URL(fileURLWithPath: a.path)) }
                            } else {
                                AttachmentChip(attachment: a)
                            }
                        }
                    }
                }
                if !item.text.isEmpty {
                    Text(item.text).font(Self.body).foregroundStyle(UI.text).textSelection(.enabled)
                        .lineSpacing(3)
                        .padding(.horizontal, 13).padding(.vertical, 9)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(UI.accent.opacity(UI.isDark ? 0.2 : 0.12))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(UI.accent.opacity(UI.isDark ? 0.22 : 0.18), lineWidth: 0.5)
                        )
                        .contextMenu {
                            Button("Copy Message") { Self.copy(item.text) }
                            if canGoBack {
                                Button("Edit from Here…", action: editFrom)
                                Button("Revert This Turn…", action: revert)
                            }
                        }
                }
                // Shown on hover, like the reply's copy button: the row keeps its height either way.
                HStack(spacing: 2) {
                    if let d = item.created {
                        Text(d.formatted(date: .omitted, time: .shortened)).font(.system(size: 10.5).monospacedDigit())
                            .foregroundStyle(UI.faint).padding(.trailing, 4)
                    }
                    IconButton(symbol: "doc.on.doc", help: "Copy message") { Self.copy(item.text) }
                    if canGoBack {
                        IconButton(symbol: "pencil", help: "Edit from here: go back to this message and change it") {
                            editFrom()
                        }
                        IconButton(
                            symbol: "arrow.uturn.backward",
                            help: "Revert this turn: put the scenes back to how they were before it"
                        ) { revert() }
                    }
                }
                .frame(height: 18).opacity(hover ? 1 : 0).animation(UI.fade, value: hover)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 30)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
        case .assistant:
            ChatAssistantRow(
                text: item.text, live: live, author: author ? item.created : nil, showsAuthor: author, turn: turn)
        case .thinking:
            ChatThinkingRow(item: item, live: live && item.duration == nil)
        case .tool:
            ChatToolRow(item: item)
        case .notice:
            Text(item.text).font(UI.small).foregroundStyle(UI.dim).frame(maxWidth: .infinity, alignment: .leading)
        case .choice:
            EmptyView()  // drawn by ChoiceCard (it needs the document and the chat)
        case .error:
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(UI.danger)
                Text(item.text).font(UI.small).foregroundStyle(UI.text).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Message text: a touch larger than the editor's UI font, for reading.
    static let body = Font.system(size: 13)

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// Inline Markdown of one block, remembered unless `remember` is off (the block a reply is writing).
    static func markdown(_ s: String, remember: Bool = true) -> AttributedString {
        if let hit = markdownCache.object(forKey: s as NSString) { return hit.value }
        let a =
            (try? AttributedString(
                markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        if remember { markdownCache.setObject(Boxed(a), forKey: s as NSString) }
        return a
    }

    /// The block a reply is writing changes every frame: its finished lines are parsed once, only its last line
    /// again, and that one isn't remembered.
    static func liveMarkdown(_ s: String) -> AttributedString {
        guard let nl = s.lastIndex(of: "\n") else { return markdown(s, remember: false) }
        return markdown(String(s[...nl])) + markdown(String(s[s.index(after: nl)...]), remember: false)
    }

    private static let markdownCache: NSCache<NSString, Boxed<AttributedString>> = {
        let c = NSCache<NSString, Boxed<AttributedString>>()
        c.countLimit = 4000
        return c
    }()
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
                    Text(item.ok == nil ? ChatToolNames.doing(item.tool ?? "") : ChatToolNames.done(item.tool ?? ""))
                        .font(UI.small).foregroundStyle(UI.text).lineLimit(1)
                    Text(item.tool ?? "tool").font(UI.monoSmall).foregroundStyle(UI.faint).lineLimit(1)
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
                    if let input = item.input, !input.isEmpty, input != "{}" {
                        Text(input.count > 600 ? String(input.prefix(600)) + "…" : input).font(UI.monoSmall)
                            .foregroundStyle(UI.faint).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !item.text.isEmpty {
                        Text(item.text).font(UI.monoSmall).foregroundStyle(UI.label2).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let img = ChatImageCache.image(item) {
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
    var label: String?
    var body: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text((label ?? "Working") + "…").font(UI.small).foregroundStyle(UI.dim).shimmering()
        }
    }
}

/// No messages yet: how to start, or what's missing.
private struct ChatEmptyState: View {
    let chat: ChatController
    static let examples = [
        "Make a 5-second title card that says “Launch day”.",
        "Make the selected text bigger and slow down its reveal.",
        "Make a YouTube thumbnail for this episode with two A/B variants.",
    ]

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(
                    LinearGradient(colors: [UI.ai.opacity(0.9), UI.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: "sparkles").font(.system(size: 20, weight: .semibold)).foregroundStyle(.white)
            }
            .frame(width: 48, height: 48)
            .shadow(color: UI.ai.opacity(0.35), radius: 14, y: 4)
            VStack(spacing: 6) {
                Text("What should we make?").font(.system(size: 16, weight: .semibold)).foregroundStyle(UI.text)
                Text(
                    chat.hasCredentials
                        ? "Ask for a scene, a thumbnail or a change. Every edit shows live and can be undone in Activity."
                        : "To chat here, add an API key from your AI provider in Settings. It stays in your Keychain."
                )
                .font(UI.small).foregroundStyle(UI.dim).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 300)
            }
            if chat.kind == .cli, CLILocator.locate(custom: ChatSettings.cliPath) == nil {
                Label(
                    "The command-line agent wasn't found. Set its path in Settings ▸ AI ▸ Experimental, or switch back to the API there.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(UI.small).foregroundStyle(UI.warning).fixedSize(horizontal: false, vertical: true)
            }
            if chat.hasCredentials {
                VStack(spacing: 8) {
                    ForEach(Array(Self.examples.enumerated()), id: \.offset) { i, s in
                        Button {
                            chat.insert(s)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: Self.icons[i]).font(.system(size: 12)).foregroundStyle(UI.ai).frame(width: 18)
                                Text(s).font(UI.small).foregroundStyle(UI.label2).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.left").font(.system(size: 9, weight: .bold)).foregroundStyle(UI.faint)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(UI.raised.opacity(0.7)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(UI.border, lineWidth: 0.5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HoverLift()).cursor(.pointingHand)
                    }
                }
                .frame(maxWidth: 360)
            } else {
                Button("Open AI settings") { ChatSettingsLink.open() }.buttonStyle(PillButtonStyle(primary: true))
                    .cursor(.pointingHand)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static let icons = ["textformat.size", "slider.horizontal.3", "photo.on.rectangle.angled"]
}

/// A card that brightens a little under the pointer and dips when pressed.
private struct HoverLift: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Lifted(configuration: configuration) }

    private struct Lifted: View {
        let configuration: Configuration
        @State private var hover = false
        var body: some View {
            configuration.label
                .brightness(hover ? 0.04 : 0)
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .animation(UI.fade, value: hover)
                .onHover { hover = $0 }
        }
    }
}

enum ChatSettingsLink {
    static func open() { (NSApp.delegate as? AppDelegate)?.showSettings(tab: "AI") }
}

/// The model's thinking. While it runs: "Thinking…" and the newest lines as they come. Then folded to
/// "Thought for 6s", click to read it all.
struct ChatThinkingRow: View {
    let item: ChatItem
    let live: Bool
    @State private var open = false
    @State private var pulse = false

    var body: some View {
        let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withMotion(Motion.snappy) { open.toggle() }
            } label: {
                HStack(spacing: 4) {
                    if !text.isEmpty && !live {
                        Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                    }
                    Image(systemName: "brain").font(.system(size: 9))
                    Text(label).font(UI.small)
                }
                .foregroundStyle(UI.dim).opacity(live && pulse ? 0.45 : 1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).cursor(text.isEmpty || live ? .arrow : .pointingHand)
            .disabled(text.isEmpty || live)
            if live, !text.isEmpty {
                ChatThinkingTail(text: text).padding(.leading, 13)
            } else if open {
                Text(text).font(UI.small).foregroundStyle(UI.dim).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 13).transition(.opacity)
            }
        }
        .onAppear {
            guard live, !Motion.reduce else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .onChange(of: live) { _, now in if !now { withAnimation(nil) { pulse = false } } }
    }

    private var label: String {
        if live { return "Thinking…" }
        guard let d = item.duration else { return "Thought" }
        return d < 1 ? "Thought briefly" : "Thought for \(Int(d.rounded()))s"
    }
}

/// The newest lines of thinking as they come, fading out at the top.
struct ChatThinkingTail: View {
    let text: String
    var body: some View {
        Text(String(text.suffix(700))).font(UI.small).foregroundStyle(UI.faint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: 64, alignment: .bottomLeading).clipped()
            .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .bottom))
    }
}

/// The header's chat list: every chat of the project, the one in front ticked.
struct ChatListMenu: View {
    let chats: ChatStore
    @State private var renaming: ChatTranscript.Summary?
    @State private var name = ""

    var body: some View {
        Menu {
            Section("Chats") {
                ForEach(chats.list.prefix(40)) { c in
                    Menu {
                        Button("Open") { chats.select(c.id) }.disabled(c.id == chats.activeID)
                        Button("Rename…") { name = c.title; renaming = c }
                        Button("Delete", role: .destructive) { chats.delete(c.id) }
                    } label: {
                        Text(Self.label(c, status: chats.status(c.id), front: c.id == chats.activeID))
                    } primaryAction: {
                        chats.select(c.id)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(UI.text).lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(UI.dim)
                if chats.runningCount > (chats.status(chats.activeID) == .running ? 1 : 0) {
                    Circle().fill(UI.ai).frame(width: 6, height: 6).help("Another chat is working")
                }
            }
            .padding(.horizontal, 6).frame(height: 26)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("This project's chats (\(chats.list.count)): open, rename or delete")
        .cursor(.pointingHand)
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Rename") { if let r = renaming { chats.rename(r.id, to: name) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    /// The chat in front's name.
    private var title: String {
        chats.list.first { $0.id == chats.activeID }?.title ?? "New chat"
    }

    static func label(_ c: ChatTranscript.Summary, status: ChatController.Status, front: Bool) -> String {
        let mark: String
        switch status {
        case .running: mark = "◉ "
        case .waiting: mark = "◆ "
        case .failed: mark = "✕ "
        case .idle: mark = front ? "✓ " : "   "
        }
        return "\(mark)\(c.title)  ·  \(ChatView.date(c.date))"
    }
}

final class Boxed<T> {
    let value: T
    init(_ v: T) { value = v }
}

/// Pictures tools returned, decoded once per row instead of on every redraw.
enum ChatImageCache {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 60
        return c
    }()

    static func image(_ item: ChatItem) -> NSImage? {
        guard let d = item.image else { return nil }
        if let hit = cache.object(forKey: item.id as NSString) { return hit }
        guard let img = NSImage(data: d) else { return nil }
        cache.setObject(img, forKey: item.id as NSString)
        return img
    }
}

/// The header's Notes button: what every chat of this project should know (`ProjectNotes`).
struct ProjectNotesButton: View {
    let project: URL
    @State private var open = false
    @State private var text = ""
    @State private var has = false

    var body: some View {
        IconButton(
            symbol: has ? "note.text" : "note.text.badge.plus",
            help: "Project notes: the script, rules, models to use — sent to the AI with every message, in every chat",
            active: has
        ) {
            text = ProjectNotes.read(project) ?? ""
            open = true
        }
        .onAppear { has = ProjectNotes.read(project) != nil }
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Project notes").font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.text)
                Text(
                    "The AI reads this with every message, in every chat of this project. Put here what you would otherwise paste again: the script, the rules of the piece, which models to use."
                )
                .font(UI.small).foregroundStyle(UI.dim).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $text).font(UI.font).scrollContentBackground(.hidden)
                    .padding(6).frame(height: 260)
                    .background(RoundedRectangle(cornerRadius: 7).fill(UI.field))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(UI.fieldBorder))
                HStack {
                    Text("\(text.count) / \(ProjectNotes.maxLength)").font(UI.monoSmall)
                        .foregroundStyle(text.count > ProjectNotes.maxLength ? UI.danger : UI.faint)
                    Spacer()
                    Button("Done") { open = false }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(14).frame(width: 440)
            .onDisappear {
                try? ProjectNotes.write(text, project: project)
                has = ProjectNotes.read(project) != nil
            }
        }
    }
}

/// A band of light passing over a label while the thing it names is happening.
private struct Shimmer: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        if Motion.reduce {
            content
        } else {
            content
                .overlay {
                    GeometryReader { g in
                        LinearGradient(
                            colors: [.clear, UI.text.opacity(0.85), .clear], startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: 56)
                        .offset(x: phase * (g.size.width + 56) - 56)
                    }
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    withAnimation(.linear(duration: 1.8).repeatForever(autoreverses: false)) { phase = 1 }
                }
        }
    }
}

extension View {
    func shimmering(_ on: Bool = true) -> some View { modifier(ShimmerIf(on: on)) }
}

private struct ShimmerIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.modifier(Shimmer()) } else { content }
    }
}

/// Reports scroll-wheel and trackpad scrolls over the view it backs: `true` for up (towards older messages).
private struct ScrollWheelWatcher: NSViewRepresentable {
    let scrolled: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = WatchView()
        v.scrolled = scrolled
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { (v as? WatchView)?.scrolled = scrolled }

    final class WatchView: NSView {
        var scrolled: (Bool) -> Void = { _ in }
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p), abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX) else { return e }
                if e.scrollingDeltaY > 0.5 { self.scrolled(true) } else if e.scrollingDeltaY < -0.5 { self.scrolled(false) }
                return e
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
