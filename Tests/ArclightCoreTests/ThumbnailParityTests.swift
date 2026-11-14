import Foundation
import Testing

@testable import ArclightMCP

/// Everything a user can do in the Thumbnail workspace, an agent can do over MCP. When a Thumbnail feature is added to
/// the editor, add it here with the tool that does the same — the test fails if that tool doesn't exist.
@Suite struct ThumbnailParityTests {
    static let uiActions: [(action: String, tool: String)] = [
        ("create a thumbnail page", "thumbnail_create"),
        ("add / resize / move / rename / delete artboards", "thumbnail_apply"),
        ("draw text, shapes, lines; edit any layer prop", "thumbnail_apply"),
        ("place an image", "asset_import"),
        ("layer effects, blend, clip, mask", "thumbnail_apply"),
        ("detach / re-link theme", "thumbnail_apply"),
        ("edit theme tokens", "theme_set"),
        ("duplicate as variant / automatic variants", "thumbnail_variants"),
        ("new artboard from template", "template_instantiate"),
        ("remove background", "image_remove_bg"),
        ("select subject", "image_select_subject"),
        ("generative fill", "image_fill"),
        ("expand", "image_expand"),
        ("upscale", "image_upscale"),
        ("generate image", "image_generate"),
        ("best frame from video / scene snapshot", "frame_extract"),
        ("add a reference (file or YouTube)", "reference_add"),
        ("analyse a reference", "reference_analyze"),
        ("feed-size check with timestamp badge", "thumbnail_render"),
        ("history / restore", "history"),
        ("export YouTube JPG / PNG", "export"),
        ("see what the user has open", "editor_state"),
        ("delete a page", "thumbnail_delete"),
    ]

    @Test func everyThumbnailActionHasAnMCPTool() {
        let names = Set(MCPServer(projectPath: nil).tools.map(\.name))
        for (action, tool) in Self.uiActions {
            #expect(names.contains(tool), "no MCP tool '\(tool)' for “\(action)”")
        }
    }
}
