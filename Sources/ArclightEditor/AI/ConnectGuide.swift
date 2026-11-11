import AppKit
import SwiftUI

/// How to connect an AI agent to Arclight's MCP server (stdio): the Claude Code command and a generic config.
enum MCPSetup {
    static var executable: String { Bundle.main.executablePath ?? "/path/to/arclight" }

    /// Claude Code, one line in a terminal.
    static var claudeCodeCommand: String { "claude mcp add -s user arclight -- \"\(executable)\" mcp" }

    /// The usual `mcpServers` entry for other clients (Cursor, Claude Desktop…). Codex uses TOML instead (README).
    static var configJSON: String {
        let exe = executable.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return """
            {
              "mcpServers": {
                "arclight": {
                  "command": "\(exe)",
                  "args": ["mcp"]
                }
              }
            }
            """
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Small outlined button that copies text and confirms with "Copied" for a moment.
struct CopyButton: View {
    let title: String
    let value: () -> String
    var symbol = "doc.on.doc"
    var help = ""
    var primary = false
    @State private var copied = false
    @State private var hover = false

    var body: some View {
        Button {
            MCPSetup.copy(value())
            withAnimation(UI.fade) { copied = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation(UI.fade) { copied = false } }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: copied ? "checkmark" : symbol).font(.system(size: 9.5, weight: .semibold))
                Text(copied ? "Copied" : title).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(primary ? UI.onAccent : (hover ? UI.text : UI.label2))
            .padding(.horizontal, 9).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(primary ? UI.accent : (hover ? UI.hover : UI.raised)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(primary ? .clear : UI.border, lineWidth: 1))
            .hitArea()
        }
        .buttonStyle(.plain).onHover { hover = $0 }.cursor(.pointingHand).help(help)
    }
}

/// Monospaced, selectable code box.
struct CodeBox: View {
    let text: String
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text).font(UI.monoSmall).foregroundStyle(UI.text).textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: true).padding(10)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(UI.field))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(UI.fieldBorder))
    }
}

/// Shown in the AI panel while no agent is connected: what this is and the two steps to get going.
struct ConnectGuide: View {
    let projectPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("No AI agent connected").font(UI.font.weight(.semibold)).foregroundStyle(UI.text)
                Text(
                    "An AI agent can build and edit this project for you while you watch. Arclight works with any agent that supports MCP — Claude Code, Cursor, Codex and others."
                )
                .font(UI.small).foregroundStyle(UI.dim).fixedSize(horizontal: false, vertical: true)
            }
            step(1, "Add Arclight to your agent (once)") {
                FlowLayout(spacing: 6) {
                    CopyButton(
                        title: "Claude Code command", value: { MCPSetup.claudeCodeCommand }, symbol: "terminal",
                        help:
                            "Copies: \(MCPSetup.claudeCodeCommand)\nRun it in a terminal, then start a new Claude Code session.",
                        primary: true)
                    CopyButton(
                        title: "MCP config (other agents)", value: { MCPSetup.configJSON }, symbol: "curlybraces",
                        help:
                            "Copies an mcpServers JSON entry (stdio) for Cursor, Claude Desktop and other MCP clients. Codex uses TOML: see the README."
                    )
                }
            }
            if let projectPath {
                step(2, "Ask it to open this project") {
                    CopyButton(
                        title: "Copy project path", value: { projectPath }, symbol: "folder",
                        help: "Paste this path to your agent, e.g. “Open <path> in Arclight and make a title card”.")
                }
            }
        }
    }

    private func step<C: View>(_ n: Int, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.system(size: 10, weight: .bold)).foregroundStyle(UI.ai)
                .frame(width: 18, height: 18).background(Circle().fill(UI.ai.opacity(0.15)))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(UI.small.weight(.medium)).foregroundStyle(UI.label2)
                content()
            }
        }
    }
}
