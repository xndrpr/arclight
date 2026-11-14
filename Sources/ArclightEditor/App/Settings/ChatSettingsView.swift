import AppKit
import ArclightCore
import SwiftUI

/// Posted when a chat setting changes, so open chats redraw (key added, backend switched).
enum ChatSettingsChange {
    static let name = Notification.Name("arclight.chatSettingsChanged")
    static func post() { NotificationCenter.default.post(name: name, object: nil) }
}

/// Settings ▸ AI ▸ Chat: the API key (Keychain), model and effort.
struct ChatSettingsView: View {
    @State private var key = ""
    @State private var saved = KeychainStore.chatKey() != nil
    @State private var model = ChatSettings.model
    @State private var effort = ChatSettings.effort
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SecureField(saved ? "Key saved — paste a new one to replace it" : "Anthropic API key", text: $key)
                    .textFieldStyle(.roundedBorder).font(UI.monoSmall).frame(maxWidth: 300)
                Button("Save") { save(key) }.buttonStyle(PillButtonStyle(primary: true)).disabled(key.isEmpty)
                if saved { Button("Remove") { save(nil) }.buttonStyle(PillButtonStyle()) }
            }
            HStack(spacing: 6) {
                StatusDot(color: saved ? UI.success : UI.faint)
                Text(saved ? "Ready — open the AI panel (⌥⌘A) ▸ Chat" : "No key — create one in the Anthropic Console")
                    .font(UI.small).foregroundStyle(UI.label2)
                if !saved {
                    Link("Open Console", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                        .font(UI.small)
                }
            }
            if let message { Text(message).font(UI.small).foregroundStyle(UI.dim) }
            HStack(spacing: 8) {
                Text("Model").font(UI.small).foregroundStyle(UI.label2).frame(width: 50, alignment: .leading)
                Picker("", selection: $model) {
                    ForEach(ChatModel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 130)
                .onChange(of: model) { _, v in ChatSettings.model = v; ChatSettingsChange.post() }
            }
            HStack(spacing: 8) {
                Text("Effort").font(UI.small).foregroundStyle(UI.label2).frame(width: 50, alignment: .leading)
                Picker("", selection: $effort) {
                    ForEach(ChatEffort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                .onChange(of: effort) { _, v in ChatSettings.effort = v; ChatSettingsChange.post() }
            }
            Text("Higher effort thinks longer: better on big changes, slower and costlier on small ones.")
                .font(UI.small).foregroundStyle(UI.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func save(_ k: String?) {
        do {
            try KeychainStore.setChatKey(k)
            saved = KeychainStore.chatKey() != nil
            key = ""
            message = k == nil ? "Key removed" : "Key saved in your Keychain"
            ChatSettingsChange.post()
        } catch { message = "\(error)" }
    }
}

/// Settings ▸ AI ▸ Experimental (only with the flag on): run the chat through the user's own installed
/// command-line agent instead of an API key.
struct ChatCLISettingsView: View {
    @State private var useCLI = ChatSettings.backend == .cli
    @State private var path = ChatSettings.cliPath
    @State private var found: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11)).foregroundStyle(UI.warning)
                Text(
                    "Uses your own Claude Code install and its login (your subscription or key). Unsupported and may change. Fine for your own use; provider terms may not allow it in an app you give to others."
                )
                .font(UI.small).foregroundStyle(UI.label2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(UI.warning.opacity(0.1)))
            Toggle("Run the chat through my installed Claude Code", isOn: $useCLI).toggleStyle(.switch)
                .controlSize(.small)
                .onChange(of: useCLI) { _, v in ChatSettings.backend = v ? .cli : .api; ChatSettingsChange.post() }
            HStack(spacing: 8) {
                TextField("Path (empty: find it automatically)", text: $path)
                    .textFieldStyle(.roundedBorder).font(UI.monoSmall).frame(maxWidth: 300)
                    .onSubmit { ChatSettings.cliPath = path; detect() }
                Button("Detect") { ChatSettings.cliPath = path; detect() }.buttonStyle(PillButtonStyle())
                    .disabled(checking)
            }
            HStack(spacing: 6) {
                StatusDot(color: found == nil ? UI.faint : UI.success)
                Text(checking ? "Looking…" : found ?? "Not found yet — press Detect").font(UI.small)
                    .foregroundStyle(UI.label2).lineLimit(1).truncationMode(.middle)
            }
        }
        .onAppear(perform: detect)
    }

    private func detect() {
        checking = true
        let custom = path
        Task.detached {
            let exe = CLILocator.locate(custom: custom)
            let text = exe.map { e in "\(e.path)" + (CLILocator.version(e).map { " · \($0)" } ?? "") }
            await MainActor.run {
                found = text
                checking = false
            }
        }
    }
}
