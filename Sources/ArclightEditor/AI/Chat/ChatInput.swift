import AppKit
import ArclightCore
import SwiftUI
import UniformTypeIdentifiers

/// The message box: Return sends, ⇧Return or ⌥Return adds a line, Esc stops a running reply. It grows with the text
/// up to about ten lines, then scrolls. Files come in from the paperclip, by pasting or by dropping them on the chat.
struct ChatInput: View {
    @ObservedObject var chat: ChatController
    @State private var height: CGFloat = ChatTextView.minHeight
    @State private var focused = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !chat.queue.isEmpty {
                ChatQueue(chat: chat).transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if !chat.pending.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(chat.pending) { a in
                            AttachmentChip(attachment: a) { chat.remove(a) }
                        }
                    }
                }
            }
            VStack(spacing: 0) {
                ChatTextView(
                    text: $chat.draft, height: $height, focused: $focused, enabled: chat.hasCredentials,
                    submit: { chat.send() },
                    escape: {
                        guard chat.running else { return false }
                        chat.stop()
                        return true
                    },
                    files: { chat.attach(files: $0) },
                    image: { chat.attach(image: $0) }
                )
                .frame(height: height)
                .overlay(alignment: .topLeading) {
                    if chat.draft.isEmpty {
                        Text(placeholder).font(UI.font).foregroundStyle(UI.faint)
                            .padding(.leading, ChatTextView.inset.width + 5).padding(.top, ChatTextView.inset.height)
                            .allowsHitTesting(false)
                    }
                }
                HStack(spacing: 2) {
                    IconButton(symbol: "paperclip", help: "Attach images or files (or paste / drop them)") {
                        pickFiles()
                    }
                    .disabled(!chat.hasCredentials)
                    ChatBrainMenu()
                    Spacer()
                    if chat.running {
                        // Something typed: Return queues it for when the AI is done. Stop stays beside it.
                        if chat.canSend {
                            IconButton(
                                symbol: "text.line.last.and.arrowtriangle.forward",
                                help: "Queue: sent when the AI finishes (Return)", active: true
                            ) { chat.send() }
                            .transition(.scale.combined(with: .opacity))
                        }
                        Button {
                            chat.stop()
                        } label: {
                            HStack(spacing: 5) {
                                if chat.stopping {
                                    ProgressView().controlSize(.mini)
                                } else {
                                    Image(systemName: "stop.fill").font(.system(size: 9))
                                }
                                Text(chat.stopping ? "Stopping…" : "Stop").font(UI.small)
                            }
                            .foregroundStyle(UI.text).padding(.horizontal, 9).frame(height: 22)
                            .background(Capsule().fill(UI.raised)).overlay(Capsule().stroke(UI.border))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain).cursor(.pointingHand).disabled(chat.stopping).help("Stop the AI (Esc)")
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    } else {
                        Button {
                            chat.send()
                        } label: {
                            Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold))
                                .foregroundStyle(chat.canSend ? UI.onAccent : UI.faint)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(chat.canSend ? UI.accent : UI.raised))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain).cursor(.pointingHand).disabled(!chat.canSend).help("Send (Return)")
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 5).padding(.bottom, 5)
                .animation(Motion.snappy, value: chat.running)
                .animation(Motion.snappy, value: chat.canSend)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(UI.field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? UI.accent.opacity(0.6) : UI.fieldBorder))
        }
        .padding(10)
        .animation(Motion.snappy, value: chat.queue)
    }

    private var placeholder: String {
        guard chat.hasCredentials else { return "Add an API key in Settings first" }
        if chat.running { return "Write the next message — it is sent when the AI finishes…" }
        return chat.transcript.pendingChoice != nil ? "Or answer in your own words…" : "Ask the AI…"
    }

    private func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.prompt = "Attach"
        p.message = "Images and PDFs are shown to the AI; text files are read; other files can be imported."
        guard p.runModal() == .OK else { return }
        chat.attach(files: p.urls)
    }
}

/// A file waiting to be sent: its thumbnail or icon, name, and a remove button.
struct AttachmentChip: View {
    let attachment: ChatAttachment
    var remove: (() -> Void)?
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            AttachmentThumb(attachment: attachment, side: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.name).font(UI.small).foregroundStyle(UI.text).lineLimit(1).truncationMode(.middle)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file))
                    .font(.system(size: 9.5)).foregroundStyle(UI.faint)
            }
            .frame(maxWidth: 130, alignment: .leading)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(UI.dim)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(hover ? UI.hover : .clear))
                }
                .buttonStyle(.plain).cursor(.pointingHand).help("Remove").onHover { hover = $0 }
            }
        }
        .padding(.leading, 4).padding(.trailing, remove == nil ? 8 : 4).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(UI.raised))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(UI.border))
        .help(attachment.path)
    }
}

/// An attachment's picture: the image itself, or the file's icon.
struct AttachmentThumb: View {
    let attachment: ChatAttachment
    let side: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable()
                    .aspectRatio(contentMode: attachment.kind == .image ? .fill : .fit)
            } else {
                Color.clear
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: attachment.id) { image = Self.load(attachment, side: side) }
    }

    static func load(_ a: ChatAttachment, side: CGFloat) -> NSImage? {
        if a.kind == .image, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a.path) as CFURL, nil) {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: Int(side * 3),
            ]
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
        return NSWorkspace.shared.icon(forFile: a.path)
    }
}

/// A plain-text editor that grows with its text and scrolls past `maxHeight`.
struct ChatTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var focused: Bool
    var enabled: Bool
    var submit: () -> Void
    /// True when it handled the key.
    var escape: () -> Bool
    var files: ([URL]) -> Void
    var image: (Data) -> Void

    static let inset = NSSize(width: 6, height: 7)
    static let lineHeight: CGFloat = 16
    static var minHeight: CGFloat { lineHeight + inset.height * 2 }
    static var maxHeight: CGFloat { lineHeight * 10 + inset.height * 2 }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let tv = ChatNSTextView()
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.font = NSFont.systemFont(ofSize: 12.5)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.textContainerInset = Self.inset
        tv.string = text
        tv.delegate = context.coordinator
        tv.owner = context.coordinator
        tv.registerForDraggedTypes([.fileURL, .png, .tiff])
        Self.applyTheme(tv)
        context.coordinator.observeTheme(tv)
        scroll.documentView = tv
        // The box's width settles after layout (and changes when the panel is resized): measure again then.
        // Measuring before it has a width wrapped every letter onto its own line and the box jumped to full height.
        tv.postsFrameChangedNotifications = true
        context.coordinator.observeWidth(tv)
        DispatchQueue.main.async {
            tv.window?.makeFirstResponder(tv)
            context.coordinator.measure(tv)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? ChatNSTextView else { return }
        if tv.string != text {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            context.coordinator.measure(tv)
        }
        if tv.isEditable != enabled { tv.isEditable = enabled }
        Self.applyTheme(tv)
    }

    static func applyTheme(_ tv: NSTextView) {
        let c = NSColor(UI.text)
        if tv.textColor != c { tv.textColor = c }
        if tv.insertionPointColor != c { tv.insertionPointColor = c }
        tv.typingAttributes[.foregroundColor] = c
        tv.typingAttributes[.font] = NSFont.systemFont(ofSize: 12.5)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatTextView
        private var themeToken: NSObjectProtocol?
        init(_ p: ChatTextView) { parent = p }
        private var frameToken: NSObjectProtocol?
        private var lastWidth: CGFloat = 0
        deinit {
            if let t = themeToken { NotificationCenter.default.removeObserver(t) }
            if let t = frameToken { NotificationCenter.default.removeObserver(t) }
        }

        func observeWidth(_ tv: NSTextView) {
            frameToken = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: tv, queue: .main
            ) { [weak self, weak tv] _ in
                guard let self, let tv, abs(tv.frame.width - self.lastWidth) > 0.5 else { return }
                self.lastWidth = tv.frame.width
                self.measure(tv)
            }
        }

        func observeTheme(_ tv: NSTextView) {
            themeToken = NotificationCenter.default.addObserver(forName: .appThemeChanged, object: nil, queue: .main) {
                [weak tv] _ in
                if let tv { ChatTextView.applyTheme(tv) }
            }
        }

        func textDidChange(_ n: Notification) {
            guard let tv = n.object as? NSTextView else { return }
            parent.text = tv.string
            measure(tv)
        }

        func textDidBeginEditing(_ notification: Notification) { parent.focused = true }
        func textDidEndEditing(_ notification: Notification) { parent.focused = false }

        /// Sizes the box to the text: one line at least, ten at most (then it scrolls).
        func measure(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            // No real width yet: keep one line (empty) or the current height rather than a wrapped-per-letter one.
            guard tv.frame.width > 40, tc.size.width > 20 else {
                if tv.string.isEmpty, abs(parent.height - ChatTextView.minHeight) > 0.5 {
                    parent.height = ChatTextView.minHeight
                }
                return
            }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            let h = min(max(ceil(used), ChatTextView.minHeight), ChatTextView.maxHeight)
            if abs(h - parent.height) > 0.5 { parent.height = h }
            tv.scrollRangeToVisible(tv.selectedRange())
        }

        func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
            switch sel {
            case #selector(NSResponder.insertNewline(_:)):
                let mods = NSApp.currentEvent?.modifierFlags ?? []
                if mods.contains(.shift) || mods.contains(.option) {
                    tv.insertNewlineIgnoringFieldEditor(nil)
                } else if !tv.hasMarkedText() {
                    parent.submit()
                }
                return true
            case #selector(NSResponder.insertLineBreak(_:)),
                #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                tv.insertNewlineIgnoringFieldEditor(nil)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.escape()
            default:
                return false
            }
        }

        /// Files or an image on a pasteboard (paste or drop): attached. False when there's nothing to attach.
        func take(_ pb: NSPasteboard) -> Bool {
            let urls =
                (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            if !urls.isEmpty {
                parent.files(urls)
                return true
            }
            if let png = Self.png(pb) {
                parent.image(png)
                return true
            }
            return false
        }

        static func png(_ pb: NSPasteboard) -> Data? {
            if let d = pb.data(forType: .png) { return d }
            guard let tiff = pb.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff) else { return nil }
            return rep.representation(using: .png, properties: [:])
        }
    }
}

/// Pasting or dropping files or images attaches them instead of inserting their paths.
final class ChatNSTextView: NSTextView {
    weak var owner: ChatTextView.Coordinator?

    override func paste(_ sender: Any?) {
        if owner?.take(.general) == true { return }
        pasteAsPlainText(sender)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .png, .tiff] + super.readablePasteboardTypes
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.hasFiles(sender.draggingPasteboard) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        Self.hasFiles(sender.draggingPasteboard) ? .copy : super.draggingUpdated(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if Self.hasFiles(sender.draggingPasteboard), owner?.take(sender.draggingPasteboard) == true { return true }
        return super.performDragOperation(sender)
    }

    static func hasFiles(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            || pb.data(forType: .png) != nil || pb.data(forType: .tiff) != nil
    }
}

/// Messages written while the AI was working, above the field: they go out together when the turn ends.
private struct ChatQueue: View {
    @ObservedObject var chat: ChatController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("QUEUED").font(.system(size: 9.5, weight: .semibold)).tracking(0.5).foregroundStyle(UI.faint)
                Spacer()
                if chat.running {
                    Button("Send now") { chat.sendQueuedNow() }
                        .buttonStyle(.plain).font(UI.small).foregroundStyle(UI.accent).cursor(.pointingHand)
                        .help("Stop what the AI is doing and send this right away")
                }
            }
            ForEach(chat.queue) { q in
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 9)).foregroundStyle(UI.faint)
                    Text(q.text.isEmpty ? "\(q.files.count) file\(q.files.count == 1 ? "" : "s")" : q.text)
                        .font(UI.small).foregroundStyle(UI.label2).lineLimit(1).truncationMode(.tail)
                    if !q.text.isEmpty, !q.files.isEmpty {
                        Image(systemName: "paperclip").font(.system(size: 9)).foregroundStyle(UI.faint)
                    }
                    Spacer(minLength: 0)
                    IconButton(symbol: "pencil", help: "Change it (back into the field)") { chat.edit(queued: q) }
                    IconButton(symbol: "xmark", help: "Remove") { chat.remove(queued: q) }
                }
                .padding(.leading, 8).frame(height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(UI.raised))
            }
        }
    }
}

/// The composer's model picker: which model answers and how hard it thinks (the same settings as Settings ▸ AI).
struct ChatBrainMenu: View {
    @State private var model = ChatSettings.model
    @State private var effort = ChatSettings.effort

    var body: some View {
        Menu {
            Section("Model") {
                ForEach(ChatModel.allCases, id: \.self) { m in
                    Button {
                        ChatSettings.model = m; model = m; ChatSettingsChange.post()
                    } label: {
                        if m == model { Label(m.label, systemImage: "checkmark") } else { Text(m.label) }
                    }
                }
            }
            Section("Thinking") {
                ForEach(ChatEffort.allCases, id: \.self) { e in
                    Button {
                        ChatSettings.effort = e; effort = e; ChatSettingsChange.post()
                    } label: {
                        if e == effort { Label(e.label, systemImage: "checkmark") } else { Text(e.label) }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("\(model.label) · \(effort.label)").font(UI.small)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(UI.dim)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("Which model answers, and how hard it thinks")
        .onReceive(NotificationCenter.default.publisher(for: ChatSettingsChange.name)) { _ in
            model = ChatSettings.model; effort = ChatSettings.effort
        }
    }
}
