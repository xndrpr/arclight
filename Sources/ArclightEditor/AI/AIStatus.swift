import ArclightCore
import Foundation
import SwiftUI

/// What the top-bar AI pill says: nobody connected, connected, or reading/editing this project right now.
struct AIStatus: Equatable {
    enum Kind: Int { case none, connected, reading, editing }
    var kind: Kind
    /// "No AI connected", "Claude Code connected", "Claude Code is editing…".
    var text: String
    /// The agent the text is about (nil for none / several).
    var agent: Int32?

    /// `legacyActiveUntil`: AI calls seen in the activity log (servers without presence files) count as editing until then.
    static func compute(
        agents: [AgentPresence], project: URL, legacyActiveUntil: Date? = nil, now: Date = Date()
    ) -> AIStatus {
        let path = Presence.key(project)
        let here = agents.filter { $0.project == path }
        if let a = here.first(where: { $0.activity(now: now) == .editing }) {
            return AIStatus(kind: .editing, text: "\(a.displayName) is editing…", agent: a.pid)
        }
        if let a = here.first(where: { $0.activity(now: now) == .reading }) {
            return AIStatus(kind: .reading, text: "\(a.displayName) is reading…", agent: a.pid)
        }
        if let until = legacyActiveUntil, until > now {
            return AIStatus(kind: .editing, text: "AI is editing…", agent: nil)
        }
        switch agents.count {
        case 0: return AIStatus(kind: .none, text: "No AI connected", agent: nil)
        case 1: return AIStatus(kind: .connected, text: "\(agents[0].displayName) connected", agent: agents[0].pid)
        default: return AIStatus(kind: .connected, text: "\(agents.count) AI agents connected", agent: nil)
        }
    }

    /// The status of `doc`'s project, including AI calls seen only in its activity log.
    static func compute(for doc: EditorDocument, agents: [AgentPresence], now: Date) -> AIStatus {
        compute(agents: agents, project: doc.url, legacyActiveUntil: doc.agentActiveUntil, now: now)
    }

    /// Reading or editing right now (the dot pulses).
    var isBusy: Bool { kind == .reading || kind == .editing }

    var dotColor: Color {
        switch kind {
        case .none: return UI.faint
        case .connected: return UI.success
        case .reading, .editing: return UI.ai
        }
    }

    /// Tooltip for the pill.
    var help: String {
        switch kind {
        case .none: return "No AI agent is connected through MCP. Click to see how to connect one. (⌥⌘A)"
        case .connected: return "\(text). Click for the AI panel: activity, notes, disconnect. (⌥⌘A)"
        case .reading, .editing: return "\(text) Click to watch its activity. (⌥⌘A)"
        }
    }
}
