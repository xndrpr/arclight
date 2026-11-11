import ArclightCore
import SwiftUI

struct ActivityRow: View {
    @ObservedObject var doc: EditorDocument
    let item: ActivityItem
    let expanded: Bool
    let toggle: () -> Void
    @State private var hover = false

    var body: some View {
        let e = item.lead
        VStack(alignment: .leading, spacing: 4) {
            Button(action: toggle) { header }.buttonStyle(.plain).cursor(.pointingHand)
                .help(expanded ? "Hide details" : "Show details, changed layers and revert")
            if expanded { details.transition(.opacity) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(expanded ? UI.raised : hover ? UI.hover : .clear)
        .overlay(alignment: .bottom) { Hairline() }
        .overlay(alignment: .leading) { if !e.ok { Rectangle().fill(UI.danger.opacity(0.8)).frame(width: 2) } }
        .onHover { hover = $0 }
    }

    private var header: some View {
        let e = item.lead
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                SourceIcon(source: e.source, agent: e.agent)
                Text(e.isAI ? e.tool : e.who)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(e.ok ? (item.write ? UI.text : UI.label2) : UI.danger)
                    .lineLimit(1)
                if item.isGroup {
                    Text("×\(item.entries.count)").font(UI.monoSmall).foregroundStyle(UI.dim)
                }
                Spacer(minLength: 4)
                RelativeTime(date: e.date)
            }
            Text(item.summary).font(UI.small).foregroundStyle(item.write ? UI.label2 : UI.dim).lineLimit(
                expanded ? nil : 2
            )
            .multilineTextAlignment(.leading).padding(.leading, 18)
            if let err = e.error {
                Text(err).font(UI.monoSmall).foregroundStyle(UI.danger.opacity(0.9)).lineLimit(expanded ? nil : 2)
                    .padding(.leading, 18)
            }
            if !expanded, item.write, e.ok, let a = item.revAfter {
                Text((item.scene ?? "") + " · rev \(item.revBefore.map(String.init) ?? "–")→\(a)")
                    .font(UI.monoSmall).foregroundStyle(UI.faint).lineLimit(1).padding(.leading, 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .hitArea()
    }

    @ViewBuilder private var details: some View {
        let e = item.lead
        VStack(alignment: .leading, spacing: 8) {
            if e.isAI {
                Text("by \(e.who)").font(UI.small).foregroundStyle(UI.dim)
            }
            if item.write, e.ok, let a = item.revAfter {
                Text((item.scene ?? "") + " · rev \(item.revBefore.map(String.init) ?? "–") → \(a)")
                    .font(UI.monoSmall).foregroundStyle(UI.dim)
            } else if let s = item.scene {
                Text(s).font(UI.monoSmall).foregroundStyle(UI.dim)
            }
            let ch = item.changed
            if !ch.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(ch.prefix(40), id: \.self) { LayerChip(doc: doc, id: $0, scene: item.scene) }
                }
            }
            if item.isGroup {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(item.entries) { sub in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(sub.date.map { $0.formatted(date: .omitted, time: .standard) } ?? "").font(
                                UI.monoSmall
                            ).foregroundStyle(UI.faint)
                            Text(sub.summary).font(UI.monoSmall).foregroundStyle(UI.label2).lineLimit(2)
                        }
                    }
                }
            }
            if let d = e.detail, !d.isEmpty, d != "{}" { RequestView(text: ActivityFeed.pretty(d)) }
            HStack(spacing: 6) {
                if item.write, item.lead.ok, let before = item.revBefore, item.scene != nil {
                    ConfirmButton(
                        title: "Revert to before this", confirmTitle: "Revert to rev \(before)",
                        help:
                            "Restore \(item.scene ?? "") as it was before this change (saved as a new revision; undoable)"
                    ) {
                        doc.restore(scene: item.scene, rev: before)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.leading, 18).padding(.top, 2)
    }
}
