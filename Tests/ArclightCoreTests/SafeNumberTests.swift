import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightMCP

/// Numbers from outside are checked before they become `Int`s (B8). These run in-process; the crash-in-a-child
/// versions stay opt-in in MCPRegressionTests.swift.
@Suite struct SafeNumberTests {
    static let wild: [Double] = [.nan, .infinity, -.infinity, 1e300, -1e300, Double(Int.max), -Double(Int.max)]

    @Test(arguments: wild) func intRejectsWildValues(_ d: Double) {
        #expect(throws: ModelError.self) { try SafeNumber.int(d, "n", in: 0...100) }
        #expect(throws: ModelError.self) { try SafeNumber.positive(d, "n", max: 100) }
    }

    @Test func intTruncatesInsideTheRangeAndNamesTheValue() throws {
        #expect(try SafeNumber.int(0, "n", in: 0...10) == 0)
        #expect(try SafeNumber.int(10.9, "n", in: 0...10) == 10)
        #expect(try SafeNumber.int(16, "n", in: 16...16384) == 16)
        #expect(throws: ModelError.self) { try SafeNumber.int(15.5, "n", in: 16...16384) }
        #expect(throws: ModelError.self) { try SafeNumber.int(-1, "limit", in: 0...10) }
        #expect(throws: ModelError.self) { try SafeNumber.int(11, "n", in: 0...10) }
        do {
            _ = try SafeNumber.int(-1, "limit", in: 0...10)
        } catch { #expect("\(error)" == "limit must be a number from 0 to 10") }
    }

    @Test func clampedIntClampsAndRejectsOnlyNonFinite() throws {
        #expect(try SafeNumber.clampedInt(1e300, "index", to: 0...5) == 5)
        #expect(try SafeNumber.clampedInt(-1e300, "index", to: 0...5) == 0)
        #expect(try SafeNumber.clampedInt(2.7, "index", to: 0...5) == 2)
        #expect(throws: ModelError.self) { try SafeNumber.clampedInt(.nan, "index", to: 0...5) }
        #expect(throws: ModelError.self) { try SafeNumber.clampedInt(.infinity, "index", to: 0...5) }
    }

    @Test func positiveNeedsAFiniteValueAboveZero() throws {
        #expect(try SafeNumber.positive(30, "fps", max: 1000) == 30)
        #expect(try SafeNumber.positive(1000, "fps", max: 1000) == 1000)
        for d in [0, -1, 1000.5] { #expect(throws: ModelError.self) { try SafeNumber.positive(d, "fps", max: 1000) } }
    }

    @Test func describeNeverTraps() {
        #expect(SafeNumber.describe(12) == "12")
        #expect(SafeNumber.describe(1e300) == "1e+300")
        #expect(SafeNumber.describe(.nan) == "nan")
        #expect(MCPServer.describe("history", ["scene": "a", "revert_to": 1e300]) == "revert a to rev 1e+300")
    }

    /// A project file edited by hand can hold any fps, duration or size; the Exporter refuses them with the
    /// CLI's and MCP's limits before it counts frames or opens a file, instead of trapping.
    @Test(.requiresMetal) func exporterRefusesWildNumbersFromAHandEditedProject() throws {
        func project(_ json: String) throws -> Project { try JSONDecoder().decode(Project.self, from: Data(json.utf8)) }
        func scene(_ json: String) throws -> Scene { try JSONDecoder().decode(Scene.self, from: Data(json.utf8)) }
        let ok = try project(#"{"name": "p", "size": [64, 36], "fps": 30}"#)
        let short = try scene(#"{"id": "s", "duration": 0.1, "nodes": []}"#)
        let ex = Exporter(renderer: try Renderer())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-wild-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var o = ExportOptions()
        o.format = .png
        let cases: [(Project, Scene, String)] = [
            (try project(#"{"fps": 1e300}"#), short, "fps must be a number above 0 and at most 1000"),
            (try project(#"{"fps": 0}"#), short, "fps must be a number above 0 and at most 1000"),
            (ok, try scene(#"{"id": "s", "duration": 1e300}"#), "scene duration (seconds) must be"),
            (ok, try scene(#"{"id": "s", "duration": 1, "fps": 5000}"#), "fps must be"),
            (try project(#"{"size": [100000, 36]}"#), short, "canvas width must be a number from 1 to 16384"),
            (try project(#"{"size": [64, -2]}"#), short, "canvas height must be"),
        ]
        for (i, (p, s, message)) in cases.enumerated() {
            let url = dir.appendingPathComponent("\(i).png")
            #expect(throws: ModelError.self) { try ex.export(scene: s, project: p, assets: nil, to: url, options: o) }
            do {
                _ = try ex.export(scene: s, project: p, assets: nil, to: url, options: o)
            } catch { #expect("\(error)".hasPrefix(message), "\(error)") }
            #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(i)_png").path))
        }
        // A valid project exports as before.
        let res = try ex.export(
            scene: short, project: ok, assets: nil, to: dir.appendingPathComponent("ok.png"), options: o)
        #expect(res.frames == 3 && res.width == 64)
    }

    @Test func sceneOpsRefuseWildNumbersAndClampIndexes() throws {
        var s = Scene(id: "s", duration: 1)
        s.nodes = [Node(id: "a", type: "group"), Node(id: "b", type: "group")]
        let moved = try SceneOps.apply([["op": "move", "id": "b", "index": -1e300]], to: s)
        #expect(moved.scene.nodes.map(\.id) == ["b", "a"])
        let added = try SceneOps.apply([["op": "add", "index": 1e300, "node": ["id": "n", "type": "group"]]], to: s)
        #expect(added.scene.nodes.last?.id == "n")
        for op: JSONValue in [
            ["op": "scene", "size": [1e300, 5]], ["op": "scene", "fps": 1e300], ["op": "scene", "duration": 1e300],
            ["op": "scene", "size": [0, 5]],
        ] {
            #expect(throws: ModelError.self) { try SceneOps.apply([op], to: s) }
        }
        // Unchanged: null clears a scene override, and a duration <= 0 is left to the validator.
        #expect(try SceneOps.apply([["op": "scene", "fps": .null, "size": .null]], to: s).scene.fps == nil)
        #expect(try SceneOps.apply([["op": "scene", "duration": 0]], to: s).scene.duration == 0)
    }

    @Test func projectSizeAndFpsHaveUpperBounds() {
        #expect(throws: (any Error).self) { try MCPServer.canvasSize([1e300, 1e300]) }
        #expect(throws: (any Error).self) { try MCPServer.canvasSize([16385, 100]) }
        #expect((try? MCPServer.canvasSize([16384, 16])) == [16384, 16])
        #expect(throws: (any Error).self) { try MCPServer.frameRate(1e300) }
        #expect((try? MCPServer.frameRate(60)) == 60)
    }
}
