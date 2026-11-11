import ArclightCore
import ArclightEditor
import ArclightMCP
import Foundation

let usage = """
    arclight — motion graphics renderer

    USAGE
      arclight [open <project.arclight>]
          Open the editor (no arguments: welcome window). Projects from Apogee (.apogee) open too.
      arclight render <project.arclight> [--scene ID] [--time S]... [--scale F] [--transparent] [--out FILE.png]
          Render frames to PNG. Several --time values write FILE_0.png, FILE_1.png, ...
      arclight export <project.arclight> [--scene ID]... [--format mp4|hevc|prores|png] [--scale F] [--fps N] [--out DIR]
          Export scenes to video or a PNG sequence (default: all scenes, mp4, into <project>/exports).
      arclight mcp [--project <project.arclight>]
          Run the MCP server on stdio (for Claude Code: claude mcp add arclight -- /path/to/arclight mcp).
      arclight docs [--out FILE.md]
          Print the scene format reference (generated from the schema).
      arclight validate <project.arclight>
          Check every scene; exits 1 on problems.
      arclight check <project.arclight>
          Check the project for problems (as MCP project_check: schema, expressions, fonts, assets, symbols,
          theme tokens); exits 1 on problems.
      arclight info <project.arclight>
          Print project and scene summary.
      arclight new <path.arclight> [--name NAME]
          Create an empty project.
      arclight --version
          Print the version.
    """

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

struct Args {
    var positional: [String] = []
    var options: [String: [String]] = [:]
    var flags: Set<String> = []
    static let flagNames: Set<String> = ["transparent"]

    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let k = String(a.dropFirst(2))
                if Args.flagNames.contains(k) {
                    flags.insert(k)
                } else if i + 1 < argv.count {
                    options[k, default: []].append(argv[i + 1]); i += 1
                } else {
                    fail("missing value for --\(k)")
                }
            } else {
                positional.append(a)
            }
            i += 1
        }
    }
    func one(_ k: String) -> String? { options[k]?.last }
}

/// The value of `--name` as a number; a non-numeric or non-finite value is an error, never a silent default.
/// `check` adds a range check (SafeNumber), whose message is shown as is.
func number(_ s: String, _ name: String, _ check: ((Double) throws -> Double)? = nil) -> Double {
    guard let d = Double(s), d.isFinite else { fail("--\(name) must be a number, got '\(s)'") }
    guard let check else { return d }
    do { return try check(d) } catch { fail("--\(name): \(error)") }
}

func scaleOption(_ s: String) -> Double {
    number(s, "scale") { try SafeNumber.positive($0, "scale", max: SafeNumber.maxScale) }
}

func openStore(_ path: String?) -> ProjectStore {
    guard let path else { fail(usage) }
    do { return try ProjectStore(url: URL(fileURLWithPath: path)) } catch { fail("cannot open project: \(error)") }
}

// Finder/LaunchServices may pass -psn_… or -NSDocumentRevisionsDebugMode; those mean "GUI".
let argv = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") && !$0.hasPrefix("-NS") }
// Copy the old Apogee folders once, only for commands that use the user library (templates, themes, symbols):
// the editor, the MCP server, render/export (user-library symbols) and check (reports missing symbols). One-shot
// commands that don't (docs, validate, info, new, --version, help) and the off-screen dev tools leave it alone.
let first = argv.first ?? ""
let usesLibrary =
    first.isEmpty || first == "open" || first.hasSuffix(".arclight") || first.hasSuffix(".apogee")
    || ["mcp", "render", "export", "check"].contains(first)
if usesLibrary { LegacyMigration.migrateUserFolders() }
guard let command = argv.first else { EditorApp.run(open: nil); exit(0) }
if command == "open" { EditorApp.run(open: argv.count > 1 ? argv[1] : nil); exit(0) }
if command.hasSuffix(".arclight") || command.hasSuffix(".apogee") { EditorApp.run(open: command); exit(0) }
let args = Args(Array(argv.dropFirst()))

switch command {
case "render":
    let store = openStore(args.positional.first)
    let scene: Scene
    do { scene = try store.scene(args.one("scene")) } catch { fail("\(error)") }
    let times = (args.options["time"] ?? ["0"]).map { number($0, "time") }
    let scale = args.one("scale").map(scaleOption) ?? 1
    let out = args.one("out") ?? "\(scene.id).png"
    do {
        let renderer = try Renderer()
        let t0 = Date()
        for (i, t) in times.enumerated() {
            let img = try renderer.image(
                scene: scene, project: store.project, assets: store.assetsURL, time: t,
                scale: scale, transparent: args.flags.contains("transparent"))
            // Several times: suffix the file name only (out.png → out_0.png), never the folders.
            let ext = (out as NSString).pathExtension
            let path =
                times.count == 1
                ? out : (out as NSString).deletingPathExtension + "_\(i)." + (ext.isEmpty ? "png" : ext)
            try ImageFile.writePNG(img, to: URL(fileURLWithPath: path))
            print(path)
        }
        FileHandle.standardError.write(
            String(format: "rendered %d frame(s) in %.0f ms\n", times.count, Date().timeIntervalSince(t0) * 1000).data(
                using: .utf8)!)
    } catch { fail("\(error)") }

case "export":
    let store = openStore(args.positional.first)
    let ids = args.options["scene"] ?? store.project.scenes
    var o = ExportOptions()
    if let f = args.one("format") {
        guard let ff = ExportFormat(rawValue: f) else { fail("format must be mp4, hevc, prores or png") }; o.format = ff
    }
    o.scale = args.one("scale").map(scaleOption) ?? 1
    o.fps = args.one("fps").map { number($0, "fps") { try SafeNumber.positive($0, "fps", max: SafeNumber.maxFPS) } }
    let dir = args.one("out").map { URL(fileURLWithPath: $0) } ?? store.url.appendingPathComponent("exports")
    do {
        let exporter = Exporter(renderer: try Renderer())
        for id in ids {
            let scene = try store.scene(id)
            let r = try exporter.export(
                scene: scene, project: store.project, assets: store.assetsURL,
                to: dir.appendingPathComponent("\(id).\(o.format.ext)"), options: o
            ) { i, n in
                if i % 15 == 0 || i == n { FileHandle.standardError.write("\r\(id): \(i)/\(n)".data(using: .utf8)!) }
            }
            FileHandle.standardError.write("\n".data(using: .utf8)!)
            print(String(format: "%@  %dx%d  %d frames  %.2fs", r.url.path, r.width, r.height, r.frames, r.seconds))
        }
    } catch { fail("\(error)") }

case "mcp":
    MCPServer(projectPath: args.one("project")).run()

case "validate":
    let store = openStore(args.positional.first)
    let engine = ExprEngine()
    var bad = false
    for s in store.orderedScenes {
        let issues = Validator.validate(s, expr: engine)
        print("\(s.id): \(issues.isEmpty ? "ok" : "\(issues.count) issue(s)")")
        for i in issues { print("  - \(i)") }
        bad = bad || !issues.isEmpty
    }
    exit(bad ? 1 : 0)

case "check":
    let problems = Doctor.check(openStore(args.positional.first))
    print(Doctor.report(problems))
    exit(problems.isEmpty ? 0 : 1)

case "info":
    let store = openStore(args.positional.first)
    let p = store.project
    print("\(p.name)  \(p.size.map(String.init).joined(separator: "x")) @ \(p.fps) fps")
    for s in store.orderedScenes {
        print("  \(s.id)  \(s.duration)s  \(s.nodes.count) nodes  rev \(s.rev)")
    }

case "new":
    guard let path = args.positional.first else { fail(usage) }
    do {
        let s = try ProjectStore.create(
            at: URL(fileURLWithPath: path),
            name: args.one("name") ?? URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
        print(s.url.path)
    } catch { fail("\(error)") }

case "snapshot":
    guard let path = args.positional.first, let out = args.one("out") else {
        fail(
            "usage: arclight snapshot <project> --out ui.png [--time S] [--select ID] [--tab activity] [--panel settings|shortcuts|inspector|timeline] [--size 1600x1000] [--setup zoom:3] [--theme light]"
        )
    }
    var o = EditorSnapshot.Options(project: path, out: out)
    o.time = args.one("time").flatMap(Double.init)
    o.select = args.one("select"); o.tab = args.one("tab"); o.panel = args.one("panel"); o.setup = args.one("setup");
    o.theme = args.one("theme")
    if let s = args.one("size")?.split(separator: "x").compactMap({ Int($0) }), s.count == 2 {
        o.width = s[0]; o.height = s[1]
    }
    exit(EditorSnapshot.run(o))

case "clickprobe":
    // Development: replays moving / jittery clicks into off-screen buttons and reports which ones fire.
    if args.positional.first == "scroll" { exit(ClickProbe.scrollCancel()) }
    if args.positional.first == "views", args.positional.count > 1 {
        exit(ClickProbe.editorViews(project: args.positional[1]))
    }
    if args.positional.first == "grid", args.positional.count >= 7, let y0 = Double(args.positional[2]),
        let y1 = Double(args.positional[3]),
        let a = Double(args.positional[4]), let b = Double(args.positional[5]), let st = Double(args.positional[6])
    {
        exit(ClickProbe.editorGrid(project: args.positional[1], y0: y0, y1: y1, x0: a, x1: b, step: st))
    }
    if args.positional.first == "repeat", args.positional.count >= 5, let y = Double(args.positional[2]),
        let a = Double(args.positional[3]), let b = Double(args.positional[4])
    {
        exit(ClickProbe.editorRepeat(project: args.positional[1], yTop: y, x0: a, x1: b))
    }
    if args.positional.first == "titlebar" { exit(ClickProbe.titlebarHits()) }
    if args.positional.first == "hits", args.positional.count > 1 {
        exit(ClickProbe.editorHits(project: args.positional[1], noSafeArea: args.positional.count > 2))
    }
    if let p = args.positional.first { exit(ClickProbe.runEditor(project: p)) }
    exit(ClickProbe.run())

case "docs":
    // Scene format reference generated from the schema (docs/scene-format.md).
    let md = Schema.markdown()
    if let out = args.one("out") {
        try? md.write(toFile: out, atomically: true, encoding: .utf8); print(out)
    } else {
        print(md)
    }

case "--version", "version":
    print("arclight \(ArclightVersion.display)")

case "help", "--help", "-h":
    print(usage)

default:
    fail("unknown command '\(command)'\n\n\(usage)")
}
