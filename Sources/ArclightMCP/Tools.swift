import ArclightCore
import Foundation

extension MCPServer {
    func makeTools() -> [Tool] {
        projectTools() + sceneTools() + thumbnailTools() + generateTools() + modelTools() + assetLibraryTools() + audioTools()
            + creatorTools()
            + outputTools()
            + editorTools()
    }
}
