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
    @ObservedObject var chat: ChatController
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
                    activity: chat.activity, revision: chat.revision
                )
                .equatable()
            }
            Hairline()
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
            ChatModelMenu()
            historyMenu
            IconButton(symbol: "square.and.pencil", help: "New chat (this one stays in the list and keeps working)") {
                doc.chats.newChat()
            }
            .disabled(chat.transcript.items.isEmpty)
            IconButton(symbol: "gearshape", help: "Chat settings") { ChatSettingsLink.open() }
        }
        .padding(.horizontal, 10).frame(height: 32)
    }

    /// The project's chats: bring one to the front, rename or delete it. A dot marks one that is working or waiting.
    private var historyMenu: some View {
        ChatListMenu(chats: doc.chats)
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
    /// The list is scrolled to (near) the bottom: new rows keep it there. Scrolling up stops following.
    @State private var pinned = true
    @State private var viewport: CGFloat = 0
    /// Where the content's top was last frame. New text grows the list downward and leaves it still; only
    /// scrolling moves it.
    @State private var scroll = ScrollMemo()

    /// Not view state: it changes on every frame of a scroll and nothing is drawn from it.
    private final class ScrollMemo { var lastTop: CGFloat = 0 }

    static func == (a: Self, b: Self) -> Bool {
        // `revision` moves with every change to the rows: comparing the rows themselves (megabytes of text and
        // pictures, 30 times a second) would cost more than the redraw it saves.
        a.revision == b.revision && a.running == b.running && a.activity == b.activity
            && a.items.count == b.items.count && a.chat === b.chat
    }

    var body: some View {
        let lastId = items.last?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(ChatBlock.group(items)) { block in
                        Group {
                            switch block {
                            case .item(let item):
                                if item.kind == .choice, let c = item.choice {
                                    ChoiceCard(doc: doc, chat: chat, choice: c)
                                } else {
                                    ChatRow(
                                        item: item, live: running && item.id == lastId,
                                        canGoBack: !running && item.checkpoint != nil,
                                        editFrom: { confirmBack(item, edit: true) },
                                        revert: { confirmBack(item, edit: false) }
                                    )
                                    .equatable()
                                }
                            case .tools(let tools):
                                ChatToolGroup(tools: tools).equatable()
                            }
                        }
                        .id(block.id)
                    }
                    if running, items.last?.kind != .thinking { ChatWorking(label: activity) }
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
                if v.top > scroll.lastTop + 0.5 {
                    if pinned { pinned = false }
                } else if v.bottom - viewport < 40 {
                    if !pinned { pinned = true }
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
            .overlay(alignment: .bottom) {
                if !pinned {
                    Button {
                        pinned = true
                        withMotion(UI.fade) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold)).foregroundStyle(UI.text)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(UI.raised))
                            .overlay(Circle().stroke(UI.border))
                            .shadow(color: .black.opacity(0.18), radius: 4, y: 1)
                    }
                    .buttonStyle(.plain).cursor(.pointingHand).help("Scroll to the latest").padding(.bottom, 8)
                    .transition(.opacity)
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
    /// User rows: the message can be gone back to (it has a checkpoint and nothing is running).
    var canGoBack = false
    var editFrom: () -> Void = {}
    var revert: () -> Void = {}
    @State private var open = false
    @State private var hover = false

    static func == (a: ChatRow, b: ChatRow) -> Bool {
        a.item == b.item && a.live == b.live && a.canGoBack == b.canGoBack
    }

    var body: some View {
        switch item.kind {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if let files = item.attachments, !files.isEmpty {
                    FlowRow(spacing: 6) {
                        ForEach(files) { a in
                            if a.kind == .image {
                                AttachmentThumb(attachment: a, side: 72)
                                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(UI.border))
                                    .help(a.name)
                                    .onTapGesture(count: 2) { NSWorkspace.shared.open(URL(fileURLWithPath: a.path)) }
                            } else {
                                AttachmentChip(attachment: a)
                            }
                        }
                    }
                }
                if !item.text.isEmpty {
                    Text(item.text).font(Self.body).foregroundStyle(UI.text).textSelection(.enabled)
                        .lineSpacing(2)
                        .padding(.horizontal, 11).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(UI.selected))
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
            ChatAssistantRow(text: item.text, live: live)
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

    /// Message text: a touch larger than the editor's UI font, for reading.
    static let body = Font.system(size: 13)

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// Inline Markdown of one block, remembered: while a reply streams only its last block is new each time.
    static func markdown(_ s: String) -> AttributedString {
        if let hit = markdownCache.object(forKey: s as NSString) { return hit.value }
        let a =
            (try? AttributedString(
                markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        markdownCache.setObject(Boxed(a), forKey: s as NSString)
        return a
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
            Text((label ?? "Working") + "…").font(UI.small).foregroundStyle(UI.dim)
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

/// The model's thinking. While it runs: "Thinking…" and the newest lines as they come. Then folded to
/// "Thought for 6s", click to read it all.
private struct ChatThinkingRow: View {
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
                // The tail of the thinking, newest at the bottom, fading out at the top.
                Text(String(text.suffix(700))).font(UI.small).foregroundStyle(UI.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: 64, alignment: .bottomLeading).clipped()
                    .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .top, endPoint: .bottom))
                    .padding(.leading, 13)
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

/// Lays children left to right, wrapping to new lines, aligned to the trailing edge.
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(proposal.width ?? .infinity, subviews)
        let w = rows.map(\.width).max() ?? 0
        let h = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: w, height: h)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for r in arrange(bounds.width, subviews) {
            var x = bounds.maxX - r.width
            for i in r.items {
                let s = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
                x += s.width + spacing
            }
            y += r.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ maxWidth: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let s = subviews[i].sizeThatFits(.unspecified)
            var r = rows[rows.count - 1]
            if !r.items.isEmpty, r.width + spacing + s.width > maxWidth {
                rows.append(Row())
                r = Row()
            }
            r.width += (r.items.isEmpty ? 0 : spacing) + s.width
            r.height = max(r.height, s.height)
            r.items.append(i)
            rows[rows.count - 1] = r
        }
        return rows
    }
}

/// The header's chat list: every chat of the project, the one in front ticked.
struct ChatListMenu: View {
    @ObservedObject var chats: ChatStore
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
            HStack(spacing: 3) {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 11, weight: .medium))
                if chats.list.count > 1 { Text("\(chats.list.count)").font(UI.monoSmall) }
            }
            .foregroundStyle(chats.runningCount > 0 ? UI.ai : UI.label2)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Chats of this project")
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Rename") { if let r = renaming { chats.rename(r.id, to: name) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
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
