import Foundation
import Testing
import UniformTypeIdentifiers

@testable import ArclightEditor

@Suite struct FilePickerTests {
    /// File ▸ Open must accept every example project, whether the system sees it as a package (app installed) or as
    /// a plain folder (unbundled build).
    @Test func openPanelAcceptsEveryExampleProject() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let examples = try FileManager.default
            .contentsOfDirectory(at: root.appendingPathComponent("Examples"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "arclight" }
        #expect(!examples.isEmpty)
        for url in examples {
            let type = try #require(try url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            #expect(FilePicker.projectTypes.contains { type.conforms(to: $0) }, "\(url.lastPathComponent): \(type)")
        }
    }

    @Test func projectTypesCoverBothExtensions() {
        let ids = FilePicker.projectTypes.map(\.identifier)
        #expect(ids.contains(UTType.folder.identifier))
        #expect(FilePicker.projectTypes.count == 3)
    }
}
