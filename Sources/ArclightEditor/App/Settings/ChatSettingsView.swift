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
    @State private var model = ChatSettings.model
    @State private var effort = ChatSettings.effort
    @State private var stages = Set(ChatSettings.directionStages)
    @State private var web = ChatSettings.webSearch

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            APIKeyField(
                name: "Anthropic API key", read: { KeychainStore.chatKey() }, write: KeychainStore.setChatKey,
                ready: "Ready — open the AI panel (⌥⌘A) ▸ Chat",
                missing: "No key — create one in the Anthropic Console",
                link: ("Open Console", URL(string: "https://console.anthropic.com/settings/keys")!),
                changed: ChatSettingsChange.post)
            HStack(spacing: 8) {
                Text("Model").font(UI.small).foregroundStyle(UI.label2).frame(width: 50, alignment: .leading)
                Picker("", selection: $model) {
                    ForEach(ChatModel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 130)
                .onChange(of: model) { _, v in
                    ChatSettings.model = v; ChatSettingsChange.post()
                }
            }
            HStack(spacing: 8) {
                Text("Effort").font(UI.small).foregroundStyle(UI.label2).frame(width: 50, alignment: .leading)
                Picker("", selection: $effort) {
                    ForEach(ChatEffort.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                .onChange(of: effort) { _, v in
                    ChatSettings.effort = v; ChatSettingsChange.post()
                }
            }
            Text("Higher effort thinks longer: better on big changes, slower and costlier on small ones.")
                .font(UI.small).foregroundStyle(UI.dim).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Ask first").font(UI.small).foregroundStyle(UI.label2).frame(width: 50, alignment: .leading)
                ForEach(ChatChoice.Stage.direction, id: \.self) { st in
                    Toggle(st.label, isOn: binding(st)).toggleStyle(.checkbox).font(UI.small)
                }
            }
            .padding(.top, 4)
            Text(
                "Before building a new scene, the AI checks these with you in the chat: a short brief, a few style frames to pick from, a storyboard of still beats, and how things move. Turn all off to build straight away, or say “just build it”."
            )
            .font(UI.small).foregroundStyle(UI.dim).fixedSize(horizontal: false, vertical: true)
            Toggle("Let the AI search the web", isOn: $web).toggleStyle(.switch).controlSize(.small).padding(.top, 4)
                .onChange(of: web) { _, v in
                    ChatSettings.webSearch = v; ChatSettingsChange.post()
                }
            Text(
                "For references, facts and finding free assets. About 1 cent per search (billed by Anthropic with the chat); up to 5 searches per reply."
            )
            .font(UI.small).foregroundStyle(UI.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func binding(_ st: ChatChoice.Stage) -> Binding<Bool> {
        Binding(
            get: { stages.contains(st) },
            set: { on in
                if on { stages.insert(st) } else { stages.remove(st) }
                ChatSettings.directionStages = Array(stages)
            })
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
                .onChange(of: useCLI) { _, v in
                    ChatSettings.backend = v ? .cli : .api; ChatSettingsChange.post()
                }
            HStack(spacing: 8) {
                TextField("Path (empty: find it automatically)", text: $path)
                    .textFieldStyle(.roundedBorder).font(UI.monoSmall).frame(maxWidth: 300)
                    .onSubmit {
                        ChatSettings.cliPath = path; detect()
                    }
                Button("Detect") {
                    ChatSettings.cliPath = path; detect()
                }.buttonStyle(PillButtonStyle())
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
