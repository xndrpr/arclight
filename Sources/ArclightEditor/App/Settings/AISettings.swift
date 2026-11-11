import AppKit
import ArclightCore
import SwiftUI

/// Settings ▸ AI: who's connected, how to connect Claude Code or any other MCP client, and this project's path.
struct AISettings: View {
    let doc: EditorDocument?
    @ObservedObject private var monitor = AgentMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(
                label: "Connected",
                note: "AI agents using Arclight right now. Each agent session runs its own Arclight MCP server."
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    if monitor.agents.isEmpty {
                        HStack(spacing: 7) {
                            StatusDot(color: UI.faint)
                            Text("No AI agent connected").font(UI.font).foregroundStyle(UI.label2)
                        }
                        .padding(.top, 2)
                    }
                    ForEach(monitor.agents) { AgentRow(agent: $0, project: doc?.url) }
                }
                .animation(Motion.snappy, value: monitor.agents.map(\.pid))
            }
            Hairline()
            SettingRow(label: "Claude Code", note: "Run once in a terminal, then start a new Claude Code session.") {
                VStack(alignment: .leading, spacing: 8) {
                    CodeBox(text: MCPSetup.claudeCodeCommand)
                    CopyButton(
                        title: "Copy command", value: { MCPSetup.claudeCodeCommand }, symbol: "terminal", primary: true)
                }
            }
            Hairline()
            SettingRow(
                label: "Other AI agents",
                note:
                    "Cursor, Codex, Claude Desktop, VS Code and any other MCP client: add Arclight as a stdio MCP server in the agent's settings."
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    CodeBox(text: MCPSetup.configJSON)
                    CopyButton(title: "Copy config", value: { MCPSetup.configJSON }, symbol: "curlybraces")
                }
            }
            if let doc {
                Hairline()
                SettingRow(
                    label: "This project", note: "Paste this path to your AI agent so it opens the right project."
                ) {
                    HStack(spacing: 8) {
                        Text(doc.url.tildePath).font(UI.monoSmall).foregroundStyle(UI.label2)
                            .lineLimit(1).truncationMode(.middle)
                        CopyButton(title: "Copy path", value: { doc.url.path }, symbol: "folder")
                    }
                }
            }
            Hairline()
            SettingRow(
                label: "Try asking",
                note:
                    "Changes appear live in the editor; every call is listed in the AI panel (⌥⌘A) with one-click revert."
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(
                        [
                            "Open this Arclight project and make a 9:16 version of the intro scene.",
                            "Make the selected text bigger and slow down its reveal.",
                            "Add a counter to 72% with a crowd where 72% of the pieces light up.",
                        ], id: \.self
                    ) { s in
                        Text("“\(s)”").font(UI.small).foregroundStyle(UI.label2).fixedSize(
                            horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}
