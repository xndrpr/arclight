import AppKit
import ArclightCore
import SwiftUI

/// Live feed of what happened to the project: every AI agent (MCP) call and every editor save, newest first,
/// grouped by day. Lives in the AI panel under the notes.
struct ActivityPanel: View {
    @ObservedObject var doc: EditorDocument
    @AppStorage(Pref.activityWho) private var who = ActivityFeed.Who.all.rawValue
    @AppStorage(Pref.activityThisScene) private var thisScene = false
    @AppStorage(Pref.activityReads) private var showReads = true
    @State private var expanded: String?
    @Namespace private var tabNS
    /// Direction of the last All / AI / You change, for the list's page slide.
    @State private var forward = true

    var body: some View {
        let filter = ActivityFeed.Filter(
            who: ActivityFeed.Who(rawValue: who) ?? .all, scene: thisScene ? doc.scene.id : nil, reads: showReads)
        let days = ActivityFeed.days(ActivityFeed.group(ActivityFeed.filter(doc.activity, filter)))
        VStack(spacing: 0) {
            filters
            Hairline()
            ZStack {
                list(days)
                    .animation(doc.playing ? nil : Motion.animation(UI.fade), value: days.isEmpty)
                    // A new filter brings in its own list: slides from the side of the tab that was clicked.
                    .id("\(who)|\(thisScene)|\(showReads)")
                    .transition(Motion.page(forward: forward))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder private func list(_ days: [ActivityFeed.Day]) -> some View {
        if days.isEmpty {
            empty(filtered: !doc.activity.isEmpty).transition(.opacity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(days) { day in
                        Section {
                            ForEach(day.items) { it in
                                ActivityRow(doc: doc, item: it, expanded: expanded == it.id) {
                                    withMotion(Motion.snappy) { expanded = expanded == it.id ? nil : it.id }
                                }
                                .transition(Motion.row)
                            }
                        } header: {
                            SmallCapsLabel(day.label, color: UI.faint)
                                .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                                .background(UI.panel)
                                .overlay(alignment: .bottom) { Hairline() }
                        }
                    }
                }
                // New entries drop in, but not while playing (the feed must never compete with playback).
                .animation(doc.playing ? nil : Motion.animation(UI.snappy), value: days.first?.items.first?.id)
            }
            .transition(.opacity)
        }
    }

    private func setWho(_ w: ActivityFeed.Who) {
        guard w.rawValue != who else { return }
        let order = ActivityFeed.Who.allCases
        forward = (order.firstIndex(of: w) ?? 0) > (order.firstIndex { $0.rawValue == who } ?? 0)
        // Let the outgoing list pick up the new direction before it animates out.
        DispatchQueue.main.async { withAnimation(Motion.snappy) { who = w.rawValue } }
    }

    private func toggle(_ change: () -> Void) {
        forward = true
        withAnimation(Motion.snappy) { change() }
    }

    private var filters: some View {
        HStack(spacing: 0) {
            SmallCapsLabel("Activity").padding(.leading, 4).padding(.trailing, 6)
                .lineLimit(1).fixedSize()
            ForEach(ActivityFeed.Who.allCases, id: \.self) { w in
                let on = who == w.rawValue
                Button {
                    setWho(w)
                } label: {
                    Text(w.title).font(.system(size: 11, weight: on ? .semibold : .regular))
                        .tabPill(
                            selected: on, padding: 7, height: 20, cornerRadius: 5, gap: 1, hitHeight: 32, id: "who",
                            in: tabNS)
                }
                .buttonStyle(.plain).cursor(.pointingHand).help(w.help)
            }
            Spacer(minLength: 2)
            IconButton(
                symbol: "scope",
                help: thisScene ? "Showing this scene only — click to show all scenes" : "Show this scene only",
                active: thisScene
            ) { toggle { thisScene.toggle() } }
            IconButton(
                symbol: showReads ? "eye" : "eye.slash",
                help: showReads ? "Hide read-only calls (scene_get, previews…)" : "Show read-only calls",
                active: !showReads
            ) { toggle { showReads.toggle() } }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
    }

    private func empty(filtered: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: filtered ? "line.3.horizontal.decrease" : "sparkles").font(.system(size: 20))
                .foregroundStyle(UI.faint)
            Text(filtered ? "Nothing matches" : "No activity yet").font(UI.font).foregroundStyle(UI.label2)
            Text(
                filtered
                    ? "Try All, all scenes, or showing reads."
                    : "Every change an AI agent makes to this project shows up here as it happens, with one-click revert."
            )
            .font(UI.small).foregroundStyle(UI.dim).multilineTextAlignment(.center).fixedSize(
                horizontal: false, vertical: true)
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension ActivityFeed.Who {
    var title: String {
        switch self {
        case .all: return "All"
        case .ai: return "AI"
        case .you: return "You"
        }
    }

    var help: String {
        switch self {
        case .all: return "Everything"
        case .ai: return "Only AI agent calls"
        case .you: return "Only your edits"
        }
    }
}
