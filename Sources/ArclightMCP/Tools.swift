import ArclightCore
import Foundation

extension MCPServer {
    func makeTools() -> [Tool] {
        projectTools() + sceneTools() + previewTools() + generateTools() + creatorTools() + outputTools() + editorTools()
    }
}
