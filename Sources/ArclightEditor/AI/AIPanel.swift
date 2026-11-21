import AppKit
import ArclightCore
import SwiftUI

/// Open/closed state of the floating AI panel (shared by all windows, remembered between launches).
/// Position, size and collapsed state live in `AIPanelLayout`.
enum AIPanelState {

    static func toggle() {
        Pref.store.set(!Pref.store.bool(forKey: Pref.aiPanel), forKey: Pref.aiPanel)
    }

    static var isOpen: Bool { Pref.store.bool(forKey: Pref.aiPanel) }

    /// Esc in an editor window: closes the AI panel if the last click in that window was inside it.
    /// Returns whether it did (the caller then swallows the key). Text fields handle Esc before this.
    @discardableResult
    static func handleEscape(in w: NSWindow?) -> Bool {
        guard isOpen, FloatingRegions.isFocused(w) else { return false }
        Pref.store.set(false, forKey: Pref.aiPanel)
        return true
    }
}

/// The AI panel's body, in two tabs. Chat: talk to the AI right here. Activity: who's connected (or how to
/// connect an outside agent), notes for the AI, and the live feed of every AI call and editor save, with revert.
/// Shown in `FloatingAIPanel` under `AIPanelHeader`.
struct AIPanelContent: View {
    let doc: EditorDocument
    @ObservedObject private var monitor = AgentMonitor.shared
    @AppStorage private var seen: String
    @AppStorage(Pref.aiPanelTab) private var tab = "chat"
    @Namespace private var tabNS

    init(doc: EditorDocument) {
        self.doc = doc
        _seen = AppStorage(wrappedValue: "", Pref.activitySeen(doc.url))
    }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            Hairline()
            ZStack {
                // The chat stays built while Activity is shown (it doesn't follow the document, so it costs nothing
                // there): coming back is instant instead of laying out a long transcript again.
                ChatView(doc: doc, chat: doc.chat).id(doc.chat.id)
                    .environment(\.chatVisible, tab == "chat")
                    .opacity(tab == "chat" ? 1 : 0)
                    .offset(x: tab == "chat" ? 0 : -18)
                    .allowsHitTesting(tab == "chat")
                    .accessibilityHidden(tab != "chat")
                if tab != "chat" {
                    VStack(spacing: 0) {
                        connection
                        Hairline()
                        NotesSection(doc: doc)
                        Hairline()
                        ActivityPanel(doc: doc)
                    }
                    .transition(Motion.page(forward: true))
                }
            }
            .clipped()
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(UI.panel)
        // The chat shows its own changes as they happen, so both tabs count as having seen the feed.
        .onAppear { seen = doc.activity.last?.id ?? "" }
        .onChange(of: doc.activity.last?.id) { _, id in seen = id ?? "" }
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach([("chat", "Chat"), ("activity", "Activity")], id: \.0) { id, title in
                Button {
                    withMotion(Motion.snappy) { tab = id }
                } label: {
                    Text(title).font(.system(size: 11.5, weight: tab == id ? .semibold : .regular))
                        .tabPill(
                            selected: tab == id, padding: 9, height: 22, cornerRadius: 5, gap: 1, hitHeight: 32,
                            id: "aitab", in: tabNS)
                }
                .buttonStyle(.plain).cursor(.pointingHand)
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
    }

    @ViewBuilder private var connection: some View {
        let agents = monitor.agents
        VStack(alignment: .leading, spacing: 8) {
            if agents.isEmpty {
                ConnectGuide(projectPath: doc.url.path)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    SmallCapsLabel(agents.count == 1 ? "Connected" : "Connected · \(agents.count)")
                        .contentTransition(.numericText())
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(agents) { a in AgentRow(agent: a, project: doc.url).transition(Motion.row) }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: agents.count > 2 ? 260 : nil)
                    .fixedSize(horizontal: false, vertical: agents.count <= 2)
                    FlowLayout(spacing: 6) {
                        CopyButton(
                            title: "Copy project path", value: { doc.url.path }, symbol: "folder",
                            help: "Paste this path to your AI agent so it opens this project")
                        ConnectMorePopover()
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(Motion.animation(UI.snappy), value: agents.map(\.pid))
    }
}

/// "Connect another…" — the setup steps in a popover, for when one agent is already connected.
private struct ConnectMorePopover: View {
    @State private var shown = false
    var body: some View {
        SmallButton(title: "Connect another…", symbol: "plus", help: "Set up another AI agent") { shown = true }
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                ConnectGuide(projectPath: nil).padding(14).frame(width: 300).background(UI.panel)
            }
    }
}

/// Top-bar pill: is an AI agent connected, and is it reading or editing this project right now?
/// Click toggles the AI panel. `compact` shows only the icon and dot.
struct AIStatusPill: View {
    let doc: EditorDocument
    var compact = false
    @ObservedObject private var monitor = AgentMonitor.shared
    @AppStorage(Pref.aiPanel) private var open = false
    @AppStorage(Pref.aiFloat) private var layoutRaw = ""
    @AppStorage private var seen: String
    @State private var hover = false

    init(doc: EditorDocument, compact: Bool = false) {
        self.doc = doc
        self.compact = compact
        _seen = AppStorage(wrappedValue: "", Pref.activitySeen(doc.url))
    }

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = AIStatus.compute(for: doc, agents: monitor.agents, now: ctx.date)
            let busy = s.isBusy
            let badge = unseen > 0 && (!open || collapsed)
            Button {
                open.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles").font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(busy || open ? UI.ai : UI.label2)
                    StatusDot(color: s.dotColor, pulsing: busy)
                    if !compact {
                        Text(s.text).font(UI.small).foregroundStyle(s.kind == .none ? UI.dim : UI.text).lineLimit(1)
                            .id(s.text).transition(.opacity)
                    }
                    if badge {
                        Text("\(min(unseen, 99))").font(.system(size: 9.5, weight: .bold)).foregroundStyle(UI.onAccent)
                            .padding(.horizontal, 5).frame(height: 15).background(Capsule().fill(UI.accent))
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 10).frame(height: 26)
                .background(Capsule().fill(open ? UI.selected : hover ? UI.hover : UI.raised))
                .overlay(Capsule().stroke(busy ? UI.ai.opacity(0.6) : UI.border))
                .barHit()
                .animation(UI.fade, value: s)
                .animation(UI.fade, value: unseen)
            }
            .buttonStyle(.plain).onHover { hover = $0 }.cursor(.pointingHand)
            .help(
                s.help + (unseen > 0 ? "\n\(unseen) new AI change\(unseen == 1 ? "" : "s") since you last looked." : "")
            )
            .fixedSize()
        }
        // The floating panel opens out of the pill.
        .background(
            GeometryReader { g in Color.clear.preference(key: AIPillFrameKey.self, value: g.frame(in: .global)) })
    }

    /// The panel is open but shows only its header (its feed isn't visible, so new changes still count as unseen).
    private var collapsed: Bool { AIPanelLayout.decode(layoutRaw)?.collapsed ?? false }

    /// AI calls logged since the panel's feed was last visible (0 until the panel has been opened once for this project).
    private var unseen: Int {
        guard !seen.isEmpty, doc.activity.contains(where: { $0.id == seen }) else { return 0 }
        return doc.activity.reversed().prefix { $0.id != seen }.filter(\.isAI).count
    }
}
