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
                    Spacer()
                    if chat.running {
                        IconButton(symbol: "stop.fill", help: "Stop (Esc)") { chat.stop() }
                    } else {
                        IconButton(symbol: "arrow.up.circle.fill", help: "Send (Return)", active: chat.canSend) {
                            chat.send()
                        }
                        .disabled(!chat.canSend)
                    }
                }
                .padding(.horizontal, 4).padding(.bottom, 3)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(UI.field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? UI.accent.opacity(0.6) : UI.fieldBorder))
        }
        .padding(10)
    }

    private var placeholder: String {
        guard chat.hasCredentials else { return "Add an API key in Settings first" }
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
        deinit { if let t = themeToken { NotificationCenter.default.removeObserver(t) } }

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
