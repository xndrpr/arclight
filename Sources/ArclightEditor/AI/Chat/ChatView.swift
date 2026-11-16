import AppKit
import ArclightCore
import SwiftUI
import UniformTypeIdentifiers

/// The AI panel's Chat tab: talk to the AI in the editor, no outside agent needed. Its changes land in the
/// Activity tab like any agent's, with revert.
struct ChatView: View {
    @ObservedObject var doc: EditorDocument
    @ObservedObject var chat: ChatController
    /// The list is scrolled to (near) the bottom: new rows keep it there. Scrolling up stops following.
    @State private var pinned = true
    @State private var viewport: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var dropping = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()
            ChatProgress(chat: chat).animation(UI.fade, value: chat.transcript.plan == nil && chat.activity == nil)
            if chat.transcript.items.isEmpty {
                ChatEmptyState(chat: chat).frame(maxHeight: .infinity, alignment: .top)
            } else {
                messages
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
            IconButton(symbol: "square.and.pencil", help: "New chat (this one stays in the history)") {
                chat.newChat()
            }
            .disabled(chat.transcript.items.isEmpty || chat.running)
            IconButton(symbol: "gearshape", help: "Chat settings") { ChatSettingsLink.open() }
        }
        .padding(.horizontal, 10).frame(height: 32)
    }

    /// Past chats of this project: open one (the current one is kept), or delete it.
    private var historyMenu: some View {
        Menu {
            if chat.archive.isEmpty {
                Text("No earlier chats")
            } else {
                Section("Earlier chats") {
                    ForEach(chat.archive.prefix(30)) { c in
                        Menu("\(c.title)  ·  \(Self.date(c.date))") {
                            Button("Open") { chat.open(archived: c.id) }.disabled(chat.running)
                            Button("Delete", role: .destructive) { chat.delete(archived: c.id) }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11, weight: .medium))
                .foregroundStyle(UI.label2)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Chat history")
        .onAppear { chat.refreshArchive() }
    }

    static func date(_ d: Date) -> String {
        let f = DateFormatter()
        f.doesRelativeDateFormatting = true
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: d)
    }

    private var messages: some View {
        let items = chat.transcript.items
        let lastId = items.last?.id
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(ChatBlock.group(items)) { block in
                        Group {
                            switch block {
                            case .item(let item):
                                if item.kind == .choice, let c = item.choice {
                                    ChoiceCard(doc: doc, chat: chat, choice: c)
                                } else {
                                    ChatRow(item: item, live: chat.running && item.id == lastId).equatable()
                                }
                            case .tools(let tools):
                                ChatToolGroup(tools: tools)
                            }
                        }
                        .id(block.id)
                    }
                    if chat.running, items.last?.kind != .thinking { ChatWorking(label: chat.activity) }
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
                                bottom: g.frame(in: .named(Self.space)).maxY, height: g.size.height))
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
                // Content that grew (a streamed word, a new row) doesn't unpin; only the user scrolling does.
                if abs(v.height - contentHeight) > 0.5 {
                    contentHeight = v.height
                } else {
                    pinned = v.bottom - viewport < 40
                }
            }
            .onChange(of: chat.revision) { _, _ in
                if pinned { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .onChange(of: chat.transcript.items.count) { old, new in
                // The user's own message always brings the list back down.
                if new > old, chat.transcript.items.last?.kind == .user {
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

    private static let bottom = "chat-bottom"
    private static let space = "chat-scroll"

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

/// Where the message list's content ends (in the scroll view's own space) and how tall it is.
private struct ChatScrollKey: PreferenceKey {
    struct Value: Equatable { var bottom: CGFloat = 0; var height: CGFloat = 0 }
    static let defaultValue = Value()
    static func reduce(value: inout Value, nextValue: () -> Value) { value = nextValue() }
}

/// One chat row: the user's message, the AI's reply (Markdown), its thinking (folded), a tool call, a notice.
struct ChatRow: View, Equatable {
    let item: ChatItem
    /// The row the running turn is writing to now.
    var live = false
    @State private var open = false

    static func == (a: ChatRow, b: ChatRow) -> Bool { a.item == b.item && a.live == b.live }

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
                        .contextMenu { Button("Copy Message") { Self.copy(item.text) } }
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 30)
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
