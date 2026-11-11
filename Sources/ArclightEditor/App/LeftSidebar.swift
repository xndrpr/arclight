import AppKit
import ArclightCore
import SwiftUI

/// Left sidebar: Scenes | History | Assets. The AI (activity, notes, connection) has its own panel on the right.
struct LeftSidebar: View {
    @ObservedObject var doc: EditorDocument
    @Namespace private var tabNS
    /// Direction of the last tab change, for the page slide.
    @State private var forward = true

    struct Tab { let id, title, icon, help: String }
    static let tabs = [
        Tab(id: "scenes", title: "Scenes", icon: "film", help: "Scenes in this project"),
        Tab(
            id: "history", title: "History", icon: "clock.arrow.circlepath",
            help: "Saved versions of the current scene — yours and the AI's. Restore or compare any of them."),
        Tab(id: "assets", title: "Assets", icon: "photo.on.rectangle", help: "Images, audio and fonts in this project"),
    ]

    /// Unknown ids show Scenes.
    private var current: String { Self.tabs.contains { $0.id == doc.leftTab } ? doc.leftTab : "scenes" }

    var body: some View {
        VStack(spacing: 0) {
            // Full labels when the sidebar is wide enough; otherwise icons, with the current tab labelled.
            ViewThatFits(in: .horizontal) {
                tabBar(compact: false)
                tabBar(compact: true)
            }
            .padding(.horizontal, 7).frame(height: 40)
            Hairline()
            ZStack {
                page(current)
                    .id(current)
                    .transition(Motion.page(forward: forward))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(UI.panel)
    }

    @ViewBuilder private func page(_ id: String) -> some View {
        switch id {
        case "history": HistoryPanel(doc: doc)
        case "assets": AssetsPanel(doc: doc)
        default: ScenesSidebar(doc: doc)
        }
    }

    private func tabBar(compact: Bool) -> some View {
        // No gaps: every point of the strip belongs to a tab (see `tab`).
        HStack(spacing: 0) {
            ForEach(Self.tabs, id: \.id) { tab($0, compact: compact) }
            Spacer(minLength: 0)
        }
    }

    private func select(_ id: String) {
        ClickTrace.fired("sidebar tab \(id)")
        guard id != current else { return }
        let order = Self.tabs.map(\.id)
        forward = (order.firstIndex(of: id) ?? 0) > (order.firstIndex(of: current) ?? 0)
        // Let the outgoing page pick up the new direction before it animates out.
        DispatchQueue.main.async { withAnimation(Motion.snappy) { doc.leftTab = id } }
    }

    private func tab(_ t: Tab, compact: Bool) -> some View {
        let on = current == t.id
        return Button {
            select(t.id)
        } label: {
            HStack(spacing: 5) {
                if compact { Image(systemName: t.icon).font(.system(size: 11.5)) }
                if !compact || on {
                    Text(t.title).font(.system(size: 12, weight: on ? .semibold : .regular)).lineLimit(1).fixedSize()
                }
            }
            .tabPill(
                selected: on, padding: 8, height: 26, cornerRadius: 6, gap: 1, hitHeight: nil,
                id: compact ? "tab-compact" : "tab", in: tabNS)
        }
        .buttonStyle(TracedPlainButtonStyle(name: "tab \(t.id)")).cursor(.pointingHand).help(t.help)
    }
}
