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
    @State private var enabled = ImageSettings.enabled
    @State private var models = ImageSettings.models

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Use fal.ai for image generation", isOn: $enabled).toggleStyle(.switch).controlSize(.small)
                .onChange(of: enabled) { _, v in ImageSettings.enabled = v }
            APIKeyField(
                name: "fal.ai API key", read: { KeychainStore.falKey() }, write: KeychainStore.setFalKey,
                ready: enabled ? "Ready" : "Key saved, turned off", on: enabled,
                missing: "No key — get one at fal.ai ▸ Dashboard ▸ Keys",
                link: ("Open fal.ai", URL(string: "https://fal.ai/dashboard/keys")!))
            picker("Images", \.generate, ModelCatalog.images)
            picker("3D models", \.model3D, ModelCatalog.models3D)
            Text(
                "Prices are fal.ai's per result (Nov 2026). Auto picks per request: Seedream 5.5 for photos and cut-outs, GPT Image 2.6 for graphics and lettering, Z-Image Turbo for drafts; Trellis 2 for 3D, Trellis for drafts. If a model rejects a request, another good one is used and the chat says which."
            )
            .font(UI.small).foregroundStyle(UI.dim).fixedSize(horizontal: false, vertical: true).frame(
                maxWidth: 420, alignment: .leading)
            DisclosureGroup("Model ids") {
                VStack(alignment: .leading, spacing: 5) {
                    model("Generate", \.generate)
                    model("Image → 3D", \.model3D)
                    model("Fill / expand", \.fill)
                    model("Background", \.removeBackground)
                    model("Upscale", \.upscale)
                    model("Depth", \.depth)
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

    /// Auto, a catalog model (with price), or the custom id typed below.
    private func picker(
        _ label: String, _ kp: WritableKeyPath<FalProvider.Models, String>, _ entries: [ModelCatalog.Entry]
    ) -> some View {
        HStack(spacing: 6) {
            Text(label).font(UI.small).foregroundStyle(UI.label2).frame(width: 90, alignment: .leading)
            Picker(
                "",
                selection: Binding(
                    get: { models[keyPath: kp] },
                    set: {
                        models[keyPath: kp] = $0; ImageSettings.models = models
                    })
            ) {
                Text("Auto (recommended)").tag(ModelCatalog.auto)
                Divider()
                ForEach(entries) { e in
                    Text("\(e.label) — \(e.priceNote) — \(e.bestFor)\(e.expensive ? " (expensive)" : "")").tag(e.id)
                }
                let current = models[keyPath: kp]
                if current != ModelCatalog.auto, !entries.contains(where: { $0.id == current }) {
                    Divider()
                    Text("Custom: \(current)").tag(current)
                }
            }
            .labelsHidden().controlSize(.small).frame(maxWidth: 330)
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
}

/// An API key kept in the Keychain: the field with Save / Remove, whether a key is saved, and where to get one.
struct APIKeyField: View {
    let name: String
    let read: () -> String?
    let write: (String?) throws -> Void
    /// The status with a key saved; `on` false greys its dot (the feature is turned off).
    let ready: String
    var on = true
    /// The status without a key, and where to get one.
    let missing: String
    let link: (title: String, url: URL)
    /// After a key was saved or removed.
    var changed: () -> Void = {}
    @State private var key = ""
    @State private var message: String?
    /// Keychain reads are cached, and saving sets `message`, so the view redraws with the new answer.
    private var saved: Bool { read() != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SecureField(saved ? "Key saved — paste a new one to replace it" : name, text: $key)
                    .textFieldStyle(.roundedBorder).font(UI.monoSmall).frame(maxWidth: 300)
                Button("Save") { save(key) }.buttonStyle(PillButtonStyle(primary: true)).disabled(key.isEmpty)
                if saved { Button("Remove") { save(nil) }.buttonStyle(PillButtonStyle()) }
            }
            HStack(spacing: 6) {
                StatusDot(color: saved && on ? UI.success : UI.faint)
                Text(saved ? ready : missing).font(UI.small).foregroundStyle(UI.label2)
                if !saved { Link(link.title, destination: link.url).font(UI.small) }
            }
            if let message { Text(message).font(UI.small).foregroundStyle(UI.dim) }
        }
    }

    private func save(_ k: String?) {
        do {
            try write(k)
            key = ""
            message = k == nil ? "Key removed" : "Key saved in your Keychain"
            changed()
        } catch { message = "\(error)" }
    }
}
