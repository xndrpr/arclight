import AVFoundation
import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightEditor

@Suite(.serialized) struct TestSupportTests {
    @Test(.requiresMetal) func tempProjectAndDoc() throws {
        let p = try TempProject("support", scenes: [ArclightCore.Scene(id: "a", duration: 2)])
        #expect(FileManager.default.fileExists(atPath: p.url.appendingPathComponent("project.json").path))
        #expect(p.url.pathExtension == "arclight" && p.store.scenes["a"] != nil)
        p.remove()
        #expect(!FileManager.default.fileExists(atPath: p.url.path))

        let (doc, project) = try makeDoc(scene: ArclightCore.Scene(id: "s", duration: 3))
        defer { project.remove() }
        #expect(doc.scene.id == "s" && doc.scene.duration == 3)
    }

    @Test func toneWritesTheRequestedFormat() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arclight-tone-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try tone(url, seconds: 1, channels: 2) { $0 < 0.5 ? 0.2 : 0.8 }
        let f = try AVAudioFile(forReading: url)
        #expect(f.length == 48000 && f.processingFormat.channelCount == 2)
        #expect(near(0.1 + 0.2, 0.3) && !near(0.1, 0.2) && near(CGFloat(1), CGFloat(1 + 1e-9)))
    }
}
