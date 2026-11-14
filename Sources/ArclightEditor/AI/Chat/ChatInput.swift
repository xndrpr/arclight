import ArclightCore
import SwiftUI

/// The message field: Return sends, ⌥Return adds a line, Esc stops a running reply.
struct ChatInput: View {
    @ObservedObject var chat: ChatController
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            TextField(
                chat.hasCredentials ? "Ask the AI…" : "Add an API key in Settings first", text: $chat.draft,
                axis: .vertical
            )
            .textFieldStyle(.plain).font(UI.font).lineLimit(1...6)
            .focused($focused)
            .disabled(!chat.hasCredentials)
            .onSubmit { chat.send() }
            .onKeyPress(.escape) {
                guard chat.running else { return .ignored }
                chat.stop()
                return .handled
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(UI.field))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(focused ? UI.accent.opacity(0.6) : UI.fieldBorder))
            if chat.running {
                IconButton(symbol: "stop.fill", help: "Stop (Esc)") { chat.stop() }.padding(.bottom, 4)
            } else {
                IconButton(symbol: "arrow.up.circle.fill", help: "Send (Return)", active: canSend) { chat.send() }
                    .disabled(!canSend).padding(.bottom, 4)
            }
        }
        .padding(10)
    }

    private var canSend: Bool {
        chat.hasCredentials && !chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
