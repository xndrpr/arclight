import ArclightCore
import Foundation

extension MCPServer {
    func makeTools() -> [Tool] {
        projectTools() + sceneTools() + thumbnailTools() + generateTools() + creatorTools() + outputTools() + editorTools()
    }
}
