import AppKit
import ArclightCore
import SwiftUI

/// Settings ▸ AI: the in-app chat, who's connected, how to connect Claude Code or any other MCP client, and this
/// project's path.
struct AISettings: View {
    let doc: EditorDocument?
    @ObservedObject private var monitor = AgentMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingRow(
                label: "Chat",
                note:
                    "Talk to the AI in the AI panel's Chat tab. Uses your own Anthropic API key, billed by Anthropic per use. The key stays in your Keychain."
            ) { ChatSettingsView() }
            if ChatSettings.cliAllowed(defaults: Pref.store) {
                Hairline()
                SettingRow(
                    label: "Experimental",
                    note: "Shown because the experimental command-line chat flag is on."
                ) { ChatCLISettingsView() }
            }
            Hairline()
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
                label: "Image generation",
                note:
                    "Optional. With your own fal.ai key, thumbnails get Generate image, Generative fill, Expand and Upscale — in the editor and for AI agents. The key stays in your Keychain. Background removal always works on this Mac, without a key."
            ) { ImageGenerationSettings() }
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
                            "Make a YouTube thumbnail for this episode with two A/B variants.",
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

/// fal.ai key (Keychain), on/off, and the models used.
struct ImageGenerationSettings: View {
    @State private var key = ""
    @State private var saved = KeychainStore.falKey() != nil
    @State private var enabled = ImageSettings.enabled
    @State private var models = ImageSettings.models
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Use fal.ai for image generation", isOn: $enabled).toggleStyle(.switch).controlSize(.small)
                .onChange(of: enabled) { _, v in ImageSettings.enabled = v }
            HStack(spacing: 8) {
                SecureField(saved ? "Key saved — paste a new one to replace it" : "fal.ai API key", text: $key)
                    .textFieldStyle(.roundedBorder).font(UI.monoSmall).frame(maxWidth: 300)
                Button("Save") { save(key) }.buttonStyle(PillButtonStyle(primary: true)).disabled(key.isEmpty)
                if saved { Button("Remove") { save(nil) }.buttonStyle(PillButtonStyle()) }
            }
            HStack(spacing: 6) {
                StatusDot(color: saved && enabled ? UI.success : UI.faint)
                Text(
                    saved
                        ? (enabled ? "Ready" : "Key saved, turned off")
                        : "No key — get one at fal.ai ▸ Dashboard ▸ Keys"
                )
                .font(UI.small).foregroundStyle(UI.label2)
                if !saved {
                    Link("Open fal.ai", destination: URL(string: "https://fal.ai/dashboard/keys")!).font(UI.small)
                }
            }
            if let message { Text(message).font(UI.small).foregroundStyle(UI.dim) }
            DisclosureGroup("Models") {
                VStack(alignment: .leading, spacing: 5) {
                    model("Generate", \.generate)
                    model("Fill / expand", \.fill)
                    model("Background", \.removeBackground)
                    model("Upscale", \.upscale)
                    Button("Reset to defaults") {
                        models = FalProvider.Models(); ImageSettings.models = models
                    }
                    .buttonStyle(PillButtonStyle()).controlSize(.small)
                }
                .padding(.top, 4)
            }
            .font(UI.small)
        }
    }

    private func model(_ label: String, _ kp: WritableKeyPath<FalProvider.Models, String>) -> some View {
        HStack(spacing: 6) {
            Text(label).font(UI.small).foregroundStyle(UI.label2).frame(width: 90, alignment: .leading)
            TextField(
                "",
                text: Binding(
                    get: { models[keyPath: kp] },
                    set: {
                        models[keyPath: kp] = $0; ImageSettings.models = models
                    })
            )
            .textFieldStyle(.roundedBorder).font(UI.monoSmall).frame(maxWidth: 240)
        }
    }

    private func save(_ k: String?) {
        do {
            try KeychainStore.setFalKey(k)
            saved = KeychainStore.falKey() != nil
            key = ""
            message = k == nil ? "Key removed" : "Key saved in your Keychain"
        } catch { message = "\(error)" }
    }
}
