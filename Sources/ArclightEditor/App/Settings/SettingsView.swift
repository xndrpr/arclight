import AppKit
import ArclightCore
import SwiftUI

/// Settings (⌘,): project canvas & frame rate, per-scene overrides, editor preferences, AI agent (MCP) setup.
struct SettingsView: View {
    let doc: EditorDocument?
    @State private var tab: String
    @State private var forward = true
    @Namespace private var tabNS

    /// `initialTab`: "Project", "Scene", "Editor" or "AI" (any case).
    init(doc: EditorDocument?, initialTab: String? = nil) {
        self.doc = doc
        let tabs = Self.tabs(doc)
        _tab = State(
            initialValue: initialTab.flatMap { w in tabs.first { $0.lowercased() == w.lowercased() } } ?? tabs[0])
    }

    private static func tabs(_ doc: EditorDocument?) -> [String] {
        doc == nil ? ["Editor", "AI"] : ["Project", "Scene", "Editor", "AI"]
    }

    var body: some View {
        let tabs = Self.tabs(doc)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(tabs, id: \.self) { t in
                    Button {
                        select(t, in: tabs)
                    } label: {
                        Text(t).font(.system(size: 12.5, weight: tab == t ? .semibold : .regular))
                            .tabPill(
                                selected: tab == t, padding: 12, height: 28, cornerRadius: 6, gap: 2, hitHeight: 40,
                                id: "tab", in: tabNS)
                    }
                    .buttonStyle(.plain).cursor(.pointingHand).help(Self.help(t))
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 30).padding(.bottom, 6)
            .background(WindowDragArea())
            Hairline()
            ZStack {
                ScrollView {
                    Group {
                        switch tab {
                        case "Project": if let doc { ProjectSettings(doc: doc) }
                        case "Scene": if let doc { SceneSettings(doc: doc) }
                        case "AI": AISettings(doc: doc)
                        default: EditorSettings(doc: doc)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(tab)
                .transition(Motion.page(forward: forward))
            }
            .clipped()
        }
        .frame(width: 640, height: 560)
        .background(UI.panel)
        .themedRoot()
    }

    private func select(_ t: String, in tabs: [String]) {
        guard t != tab else { return }
        forward = (tabs.firstIndex(of: t) ?? 0) > (tabs.firstIndex(of: tab) ?? 0)
        DispatchQueue.main.async { withAnimation(Motion.snappy) { tab = t } }
    }

    private static func help(_ tab: String) -> String {
        switch tab {
        case "Project": return "Name, canvas size, frame rate and folder of this project"
        case "Scene": return "Overrides for the current scene only"
        case "AI": return "Connect AI agents (Claude Code, Cursor, Codex…) through MCP"
        default: return "Editor theme and preferences"
        }
    }
}

struct SettingRow<C: View>: View {
    let label: String
    var note: String? = nil
    @ViewBuilder let content: C
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label).font(UI.font).foregroundStyle(UI.text)
                if let note {
                    Text(note).font(UI.small).foregroundStyle(UI.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 170, alignment: .leading)
            content.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
    }
}
