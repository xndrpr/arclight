import Foundation

/// Turns a Blender file into a .glb (with its animation) through the user's own Blender, run in the background.
/// Arclight can't read .blend itself.
public enum BlendConverter {
    /// Blender's executable: the app in /Applications (or ~/Applications), else `blender` on the PATH.
    public static func locate() -> URL? {
        let fm = FileManager.default
        let apps = [
            "/Applications/Blender.app", NSHomeDirectory() + "/Applications/Blender.app",
        ]
        for a in apps {
            let exe = a + "/Contents/MacOS/Blender"
            if fm.isExecutableFile(atPath: exe) { return URL(fileURLWithPath: exe) }
        }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin")
            .split(separator: ":")
        {
            let exe = "\(dir)/blender"
            if fm.isExecutableFile(atPath: exe) { return URL(fileURLWithPath: exe) }
        }
        return nil
    }

    /// The script Blender runs: export everything as one binary glTF with animations, shape keys and skins.
    /// Paths come after `--` so they are never parsed as Python.
    static let script = """
        import bpy, sys
        out = sys.argv[sys.argv.index('--') + 1]
        bpy.ops.export_scene.gltf(filepath=out, export_format='GLB', export_animations=True, \
        export_morph=True, export_skins=True, export_apply=False)
        """

    static func arguments(blend: URL, out: URL) -> [String] {
        ["-b", blend.path, "--python-expr", script, "--", out.path]
    }

    /// Exports `blend` to a .glb next to `out` and returns it. Takes up to `timeout` seconds.
    public static func convert(_ blend: URL, to out: URL, timeout: TimeInterval = 180) throws -> URL {
        guard let exe = locate() else {
            throw MeshError.unsupported(
                "Arclight can't open .blend files and Blender isn't installed here. In Blender: File ▸ Export ▸ glTF 2.0 (.glb), with Animation on, then import the .glb."
            )
        }
        try? FileManager.default.removeItem(at: out)
        let p = Process()
        p.executableURL = exe
        p.arguments = arguments(blend: blend, out: out)
        // Blender's log goes to a file: a pipe nobody reads would fill up and stall it.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arclight-blender-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let logHandle = try FileHandle(forWritingTo: log)
        defer { try? logHandle.close() }
        p.standardOutput = logHandle
        p.standardError = logHandle
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        if p.isRunning {
            p.terminate()
            throw MeshError.invalid("Blender took longer than \(Int(timeout)) s to export \(blend.lastPathComponent)")
        }
        let err = String(decoding: ((try? Data(contentsOf: log)) ?? Data()).suffix(400), as: UTF8.self)
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: out.path) else {
            throw MeshError.invalid(
                "Blender couldn't export \(blend.lastPathComponent)" + (err.isEmpty ? "" : ": \(err)"))
        }
        return out
    }
}

extension Mesh {
    /// One line about a model for the AI: size in triangles and the clips it can play.
    public var summary: String {
        var s = "\(triangleCount) triangles"
        if let r = rig, r.animated {
            let clips = r.clips.enumerated().map { i, c in
                "\(i): \(c.name) (\(String(format: "%.2g", c.duration)) s)"
            }
            s +=
                "; animation clips — \(clips.joined(separator: ", ")). A model layer plays clip 0 on loop; set clip, clipSpeed, clipOffset (out of step copies) or clipTime."
        } else {
            s += "; no animation (it moves only as a whole layer)"
        }
        return s
    }
}
