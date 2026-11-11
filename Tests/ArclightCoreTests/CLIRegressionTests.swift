import Foundation
import Testing

@testable import ArclightCore

// Regression tests for the CLI (`arclight render` / `export`) and SceneOps bugs found in the 0.1.0 release work. The executable target cannot be
// imported, so the CLI items run the built `arclight` binary in a child process.

private final class BundleAnchor {}

/// Runs the built `arclight` binary with a private home folder and presence folder.
private enum CLIChild {
    struct Outcome {
        var reason: Process.TerminationReason
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func binary() throws -> URL {
        let bundle = Bundle(for: BundleAnchor.self)
        try #require(bundle.bundlePath.hasSuffix(".xctest"), "test bundle not found: \(bundle.bundlePath)")
        let url = URL(fileURLWithPath: bundle.bundlePath).deletingLastPathComponent().appendingPathComponent("arclight")
        try #require(FileManager.default.isExecutableFile(atPath: url.path), "arclight binary missing next to tests")
        return url
    }

    /// `home` overrides the private home folder (the caller creates and removes it).
    static func run(_ args: [String], home given: URL? = nil) throws -> Outcome {
        let bin = try binary()
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("arclight-ki-cli-\(UUID().uuidString)")
        let home = given ?? tmp.appendingPathComponent("home"), presence = tmp.appendingPathComponent("presence")
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        try fm.createDirectory(at: presence, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let outURL = tmp.appendingPathComponent("out.txt"), errURL = tmp.appendingPathComponent("err.txt")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        let p = Process()
        p.executableURL = bin
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["CFFIXED_USER_HOME"] = home.path
        env["ARCLIGHT_PRESENCE_DIR"] = presence.path
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = try FileHandle(forWritingTo: outURL)
        p.standardError = try FileHandle(forWritingTo: errURL)
        try p.run()
        p.waitUntilExit()
        return Outcome(
            reason: p.terminationReason, status: p.terminationStatus,
            stdout: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
            stderr: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
    }
}

/// A tiny project (64x36, 10 fps) with one 0.2 s scene "s", in a scratch folder.
private struct CLIFixture {
    let root: URL
    let project: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arclight-ki-fix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        project = root.appendingPathComponent("p.arclight")
        let store = try ProjectStore.create(at: project, name: "p")
        var p = store.project
        p.size = [64, 36]
        p.fps = 10
        try store.update(project: p)
        var s = ArclightCore.Scene(id: "s", duration: 0.2)
        s.nodes = [
            Node(id: "r", type: "shape", props: ["shape": .value("rect"), "width": .value(20), "height": .value(10)])
        ]
        try store.save(scene: s)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func exists(_ rel: String) -> Bool { FileManager.default.fileExists(atPath: root.appendingPathComponent(rel).path) }
}

@Suite(.serialized) struct CLIRegressionTests {
    /// CLI-1: with several --time values and an out path whose directory contains ".png", only the extension is suffixed (out_0.png, out_1.png).
    @Test(.requiresMetal) func cli1_renderSuffixesOnlyTheFileName() throws {
        let fx = try CLIFixture()
        defer { fx.remove() }
        try FileManager.default.createDirectory(
            at: fx.root.appendingPathComponent("a.png.d"), withIntermediateDirectories: true)
        let out = fx.root.appendingPathComponent("a.png.d/out.png").path
        let r = try CLIChild.run(["render", fx.project.path, "--time", "0", "--time", "0.1", "--out", out])
        #expect(r.status == 0, "exit \(r.status): \(r.stderr)")
        #expect(fx.exists("a.png.d/out_0.png") && fx.exists("a.png.d/out_1.png"))
        // An out path without an extension gets one per frame instead of every frame overwriting it.
        let bare = fx.root.appendingPathComponent("frame").path
        let r2 = try CLIChild.run(["render", fx.project.path, "--time", "0", "--time", "0.1", "--out", bare])
        #expect(r2.status == 0, "exit \(r2.status): \(r2.stderr)")
        #expect(fx.exists("frame_0.png") && fx.exists("frame_1.png"))
    }

    /// CLI-2: a non-numeric --time or --scale must fail with a non-zero exit and an error message, not silently become 0 / 1.
    @Test(
        .requiresMetal,
        arguments: [
            ["--time", "abc"], ["--scale", "abc"], ["--time", "nan"], ["--scale", "1e300"], ["--scale", "0"],
            ["--scale", "inf"],
        ])
    func cli2_renderTurnsBadNumbersIntoDefaults(_ bad: [String]) throws {
        let fx = try CLIFixture()
        defer { fx.remove() }
        let out = fx.root.appendingPathComponent("o.png").path
        let r = try CLIChild.run(["render", fx.project.path] + bad + ["--out", out])
        #expect(r.status != 0, "exit status")
        #expect(r.stderr.contains(bad[0]), "error message names the option: \(r.stderr)")
        #expect(!fx.exists("o.png"), "nothing rendered")
    }

    /// CLI-2: export checks --scale and --fps the same way.
    @Test(arguments: [["--scale", "abc"], ["--fps", "x"], ["--fps", "1e300"], ["--scale", "-1"]])
    func cli2_exportRejectsBadNumbers(_ bad: [String]) throws {
        let fx = try CLIFixture()
        defer { fx.remove() }
        let out = fx.root.appendingPathComponent("exp").path
        let r = try CLIChild.run(["export", fx.project.path, "--format", "png"] + bad + ["--out", out])
        #expect(r.status != 0, "exit status")
        #expect(r.stderr.contains(bad[0]), "error message names the option: \(r.stderr)")
        #expect(!fx.exists("exp"), "nothing exported")
    }

    /// CLI-3: `export --format png` works (ExportFormat includes png): exit 0 and `<out>/s_png/s_00000.png` exists.
    @Test(.requiresMetal) func cli3_exportPngWorks() throws {
        let fx = try CLIFixture()
        defer { fx.remove() }
        let out = fx.root.appendingPathComponent("exp").path
        let r = try CLIChild.run(["export", fx.project.path, "--format", "png", "--out", out])
        #expect(r.status == 0, "exit \(r.status): \(r.stderr)")
        #expect(fx.exists("exp/s_png/s_00000.png") && fx.exists("exp/s_png/s_00001.png"))
    }

    /// CLI-3: the usage text and the bad-format error must list png among the formats.
    @Test func cli3_exportFormatMessagesMentionPng() throws {
        let fx = try CLIFixture()
        defer { fx.remove() }
        let bad = try CLIChild.run(["export", fx.project.path, "--format", "bogus"])
        let help = try CLIChild.run(["--help"])
        try #require(bad.status != 0, "setup: a bogus format is rejected")
        #expect(bad.stderr.contains("png"), "error: \(bad.stderr)")
        #expect(help.stdout.contains("--format mp4|hevc|prores|png"), "usage line")
    }

    /// The one-time Apogee → Arclight library copy runs only for commands that use the user library (editor, mcp,
    /// render, export, check), never for one-shot commands like docs, validate, info, new, --version or --help.
    @Test func legacyLibraryIsCopiedOnlyByCommandsThatUseIt() throws {
        let fx = try CLIFixture()
        defer { fx.remove() }
        let home = fx.root.appendingPathComponent("home")
        let support = home.appendingPathComponent("Library/Application Support")
        let old = support.appendingPathComponent("Apogee/library/templates")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: old.appendingPathComponent("t.json"))
        let migrated = support.appendingPathComponent("Arclight/library/templates/t.json")
        let readOnly: [[String]] = [
            ["docs"], ["validate", fx.project.path], ["info", fx.project.path], ["--version"], ["--help"],
            ["new", fx.root.appendingPathComponent("n.arclight").path],
        ]
        for args in readOnly {
            let r = try CLIChild.run(args, home: home)
            #expect(r.status == 0, "\(args): exit \(r.status) \(r.stderr)")
            #expect(!FileManager.default.fileExists(atPath: migrated.path), "\(args) copied the library")
        }
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("Arclight").path))
        // The MCP server uses the library, so it copies it (stdin is empty, so it exits at once).
        let r = try CLIChild.run(["mcp"], home: home)
        #expect(r.status == 0, "mcp: exit \(r.status) \(r.stderr)")
        #expect(FileManager.default.fileExists(atPath: migrated.path), "mcp copied the library")
    }

    /// CLI-4: `remove` returns the removed ids in a deterministic order (the order requested), not Set order.
    @Test func cli4_removeReturnsIdsInRequestOrder() throws {
        var s = ArclightCore.Scene(id: "s", duration: 1)
        s.nodes = (0..<12).map { Node(id: "n\($0)", type: "shape") }
        let order = ["n7", "n2", "n11", "n0", "n5", "n9", "n3", "n10", "n1", "n8", "n4", "n6"]
        let r = try SceneOps.apply([["op": "remove", "ids": .array(order.map { .string($0) })]], to: s)
        try #require(Set(r.changed) == Set(order), "setup: same ids")
        #expect(r.changed == order)
        // A root is followed by its descendants, and an id named twice (or under a removed root) appears once.
        var t = ArclightCore.Scene(id: "t", duration: 1)
        t.nodes = [
            Node(id: "g", type: "group"), Node(id: "c", type: "shape", parent: "g"), Node(id: "x", type: "shape"),
        ]
        let r2 = try SceneOps.apply([["op": "remove", "ids": ["x", "g", "c", "x"]]], to: t)
        #expect(r2.changed == ["x", "g", "c"])
        #expect(r2.scene.nodes.isEmpty)
    }
}
