import ArclightCore
import Foundation

extension MCPServer {
    /// `ask_choice` for the editor's chat when it runs through a command-line agent (`arclight mcp --chat`). The
    /// editor reads the call from the agent's output and shows the card; this only checks the input and tells the
    /// model to stop and wait.
    func chatChoiceTool() -> Tool {
        let def = ChatChoice.tool
        return Tool(
            name: ChatChoice.toolName, description: def["description"]?.string ?? "",
            schema: def["input_schema"] ?? schema([:]), readOnly: true
        ) { args in
            do {
                _ = try ChatChoice.parse(id: "check", input: args)
            } catch {
                throw ToolError("\(error)")
            }
            return text(
                "Shown to the user as a card in the chat. Stop now: end your turn without more tools or text. Their answer arrives as the next message."
            )
        }
    }
}
