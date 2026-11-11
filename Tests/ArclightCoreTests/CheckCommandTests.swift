import Foundation
import Testing

@testable import ArclightCore

/// `Doctor.report`: the text `arclight check` and MCP `project_check` print.
@Suite struct CheckCommandTests {
    @Test func reportFormat() {
        #expect(Doctor.report([]) == "no problems")
        let p = [
            Problem(
                severity: .error, kind: "asset", scene: "s", node: "img", message: "image 'a.png' not found in assets/"),
            Problem(
                severity: .warning, kind: "token", scene: "s", node: nil,
                message: "background uses $paper, which is not in the theme"),
        ]
        #expect(
            Doctor.report(p) == """
                error [asset] s/img: image 'a.png' not found in assets/
                warning [token] s: background uses $paper, which is not in the theme
                """)
    }

    @Test func reportsAProjectsProblems() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arclight-check-\(UUID().uuidString).arclight")
        defer { try? FileManager.default.removeItem(at: dir) }
        let st = try ProjectStore.create(at: dir, name: "t")
        var s = ArclightCore.Scene(id: "s", duration: 2)
        s.nodes = [Node(id: "img", type: "image", props: ["src": .value("missing.png")])]
        try st.save(scene: s)
        #expect(
            Doctor.report(Doctor.check(try ProjectStore(url: dir)))
                == "error [asset] s/img: image 'missing.png' not found in assets/")
    }
}
