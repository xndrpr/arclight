import ArclightCore
import SwiftUI

/// One connected agent: name, what it's doing, which project, its last call, and Disconnect.
struct AgentRow: View {
    let agent: AgentPresence
    /// The window's project (nil in Settings without a project).
    let project: URL?
    @ObservedObject private var monitor = AgentMonitor.shared

    var body: some View {
        SwiftUI.TimelineView(.periodic(from: .now, by: 1)) { ctx in
            content(now: ctx.date)
        }
    }

    private func content(now: Date) -> some View {
        let act = agent.activity(now: now)
        return VStack(alignment: .leading, spacing: 5) {
            titleRow(act)
            subtitle(now)
            lastCall
            ConfirmButton(
                title: "Disconnect", confirmTitle: "Disconnect \(agent.displayName)?", symbol: "xmark.circle",
                help:
                    "End this agent's connection to Arclight. Its MCP server stops; restart the agent session to reconnect."
            ) {
                withAnimation(Motion.snappy) { monitor.disconnect(agent) }
            }
            .padding(.top, 2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(UI.raised))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(act == .idle ? UI.border : UI.ai.opacity(0.5), lineWidth: 1))
        .animation(UI.fade, value: act)
    }

    private func titleRow(_ act: AgentPresence.Activity) -> some View {
        HStack(spacing: 7) {
            StatusDot(color: act == .idle ? UI.success : UI.ai, pulsing: act != .idle)
            Text(agent.displayName).font(UI.font.weight(.semibold)).foregroundStyle(UI.text).lineLimit(1)
            if let v = agent.clientVersion { Text(v).font(UI.monoSmall).foregroundStyle(UI.faint).lineLimit(1) }
            Spacer(minLength: 4)
            stateChip(act)
        }
    }

    private func subtitle(_ now: Date) -> some View {
        let a = Text(connectedText(now)).font(UI.small).foregroundStyle(UI.dim)
        let b = Text(" · ").font(UI.small).foregroundStyle(UI.faint)
        let c = Text(projectText).font(UI.small).foregroundStyle(onThisProject ? UI.ai : UI.dim)
        return (a + b + c).lineLimit(1)
    }

    @ViewBuilder private var lastCall: some View {
        if let s = agent.lastSummary, let tool = agent.lastTool {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(tool).font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(agent.lastOk == false ? UI.danger : UI.label2)
                Text(s).font(UI.small).foregroundStyle(UI.dim).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 2)
                RelativeTime(date: agent.lastCallDate)
            }
            .help("Last call: \(tool) — \(s)")
        }
    }

    private var onThisProject: Bool { project.map { agent.project == Presence.key($0) } ?? false }

    private var projectText: String {
        if onThisProject { return "this project" }
        guard let p = agent.project else { return "no project open yet" }
        return URL(fileURLWithPath: p).deletingPathExtension().lastPathComponent
    }

    private func connectedText(_ now: Date) -> String {
        let r = ActivityFeed.relative(agent.startedDate, now: now)
        return r == "now" || r.isEmpty ? "Connected just now" : "Connected \(r) ago"
    }

    @ViewBuilder private func stateChip(_ a: AgentPresence.Activity) -> some View {
        let (label, color): (String, Color) =
            switch a {
            case .idle: ("Idle", UI.dim)
            case .reading: ("Reading", UI.ai)
            case .editing: ("Editing", UI.ai)
            }
        Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(color)
            .padding(.horizontal, 6).frame(height: 17)
            .background(Capsule().fill(color.opacity(0.14)))
            .contentTransition(.opacity)
    }
}

/// A small status dot that gently pulses while busy (static with reduced motion and in off-screen snapshots).
struct StatusDot: View {
    let color: Color
    var pulsing = false
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay { if pulsing && !Motion.reduce && !Offscreen.isActive { Pulse(color: color, size: size) } }
    }

    private struct Pulse: View {
        let color: Color
        let size: CGFloat
        @State private var on = false
        var body: some View {
            Circle().stroke(color, lineWidth: 1.5).frame(width: size, height: size)
                .scaleEffect(on ? 2.2 : 1).opacity(on ? 0 : 0.8)
                .onAppear { withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) { on = true } }
        }
    }
}
