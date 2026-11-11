import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightMCP

@Suite(.serialized) struct TemplateTests {
    @Test func builtInsDecodeInstantiateAndValidate() throws {
        #expect(BuiltInTemplates.all.count == BuiltInTemplates.sources.count, "every built-in template decodes")
        let engine = ExprEngine()
        for t in BuiltInTemplates.all {
            for canvas in [(1920, 1080), (1080, 1920)] {
                let s = try Templates.instantiate(t, params: [:], sceneId: "x", canvas: canvas)
                let issues = Validator.validate(s, expr: engine)
                #expect(issues.isEmpty, "\(t.id) @\(canvas): \(issues)")
                #expect(
                    !String(data: try JSONEncoder().encode(s), encoding: .utf8)!.contains("{{"),
                    "\(t.id) leaves no placeholders")
            }
        }
    }

    @Test func builtInSampleTextIsEnglish() {
        for source in BuiltInTemplates.sources {
            #expect(!source.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }, "no Cyrillic sample text")
        }
        let cascade = BuiltInTemplates.all.first { $0.id == "spotlight-cascade" }
        #expect(cascade?.params.map(\.default) == [45, "of people spent yesterday", "feeling lonely."])
    }

    @Test func examplesValidateAndPassTheProjectCheck() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let dir = root.appendingPathComponent("Examples")
        let examples = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "arclight" }.sorted { $0.path < $1.path }
        #expect(examples.count == 8)
        let engine = ExprEngine()
        for url in examples {
            let store = try ProjectStore(url: url)
            #expect(!store.orderedScenes.isEmpty, "\(url.lastPathComponent) has scenes")
            for s in store.orderedScenes {
                let issues = Validator.validate(s, expr: engine)
                #expect(issues.isEmpty, "\(url.lastPathComponent)/\(s.id): \(issues)")
            }
            #expect(Doctor.check(store).isEmpty, "\(url.lastPathComponent): \(Doctor.check(store))")
        }
    }

    @Test func substitutionTypesAndInterpolation() throws {
        let t = Template(
            id: "t", name: "T", params: [.init(name: "v", default: 5), .init(name: "word", default: "hi")],
            scene: [
                "duration": 2,
                "nodes": [
                    [
                        "id": "a", "type": "text", "text": "{{word}} there", "value": "{{v}}",
                        "x": ["expr": "{{CX}} - 10"], "size": "{{v}}",
                    ]
                ],
            ])
        let s = try Templates.instantiate(t, params: ["v": 42], sceneId: "s", canvas: (1000, 500))
        let n = s.node("a")!
        #expect(
            n.props["text"] == .value("hi there") && n.props["value"] == .value(42) && n.props["size"] == .value(42))
        #expect(n.props["x"] == .expr("500 - 10"))
        #expect(throws: (any Error).self) {
            try Templates.instantiate(t, params: ["nope": 1], sceneId: "s", canvas: (10, 10))
        }
    }

    @Test func makeFromSceneAndRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arclight-tpl-\(UUID().uuidString).arclight")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try ProjectStore.create(at: dir, name: "t")
        var s = Scene(id: "brand", duration: 3)
        s.nodes = [Node(id: "headline", type: "text", props: ["text": .value("Launch day"), "size": .value(90)])]
        let t = try Templates.make(
            from: s, id: "brand-title", name: "Brand title", description: nil,
            params: [
                (Template.Param(name: "headline"), "headline.text"), (Template.Param(name: "len"), "scene.duration"),
            ])
        #expect(t.params.map(\.default) == ["Launch day", 3])
        _ = try Templates.save(t, scope: .project, project: dir)
        let loaded = try #require(Templates.get("brand-title", project: dir))
        let made = try Templates.instantiate(
            loaded, params: ["headline": "Hello", "len": 4], sceneId: "new", canvas: (1920, 1080))
        #expect(made.duration == 4 && made.node("headline")?.props["text"] == .value("Hello"))
    }

    @Test(.requiresMetal) func mcpTemplateTools() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arclight-tplm-\(UUID().uuidString).arclight")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try ProjectStore.create(at: dir, name: "t")
        let server = MCPServer(projectPath: dir.path)
        let msg: JSONValue = [
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": [
                "name": "template_instantiate",
                "arguments": ["template": "stat-crowd", "scene": "stat", "params": ["value": 72]],
            ],
        ]
        server.handle(String(data: try JSONEncoder().encode(msg), encoding: .utf8)!)
        let store = try ProjectStore(url: dir)
        let scene = try store.scene("stat")
        #expect(scene.nodes.contains { $0.id == "crowd" })
        #expect(ActivityLog.read(project: dir).last?.summary == "new scene stat from template stat-crowd")
        // The counter tracks the lights and reaches exactly the value.
        let ev = Evaluator(theme: store.project.theme)
        let v = ev.evaluate(scene, T: 5.5).first { $0.node.id == "counter" }?.props["value"]
        #expect(v == .number(72))
    }
}

@Suite(.serialized) struct DoctorExportTests {
    @Test func doctorFindsProblems() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "arclight-doc-\(UUID().uuidString).arclight")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try ProjectStore.create(at: dir, name: "t")
        var s = Scene(id: "s", duration: 2)
        s.audio = AudioRef(src: "missing.wav")
        s.nodes = [
            Node(
                id: "t", type: "text",
                props: ["text": .value("Hi"), "font": .value("NoSuchFont-Bold"), "color": .value("$brand")]),
            Node(id: "i", type: "image", props: ["src": .value("nope.png")]),
            Node(id: "r", type: "repeater", props: ["items": .value([["symbol": "brand/logo"]])]),
        ]
        try store.save(scene: s)
        let kinds = Doctor.check(store).map(\.kind).sorted()
        #expect(kinds == ["asset", "asset", "font", "symbol", "token"])
    }

    @Test(.requiresMetal) func pngSequenceAndStill() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-png-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        var s = Scene(id: "s", duration: 0.2)
        s.nodes = [Node(id: "r", type: "shape", props: ["x": .value(50), "y": .value(50)])]
        let p = Project(name: "p", size: [160, 90])
        let ex = Exporter(renderer: try Renderer())
        var o = ExportOptions(); o.format = .png; o.transparent = true
        let r = try ex.export(scene: s, project: p, assets: nil, to: dir.appendingPathComponent("s.png"), options: o)
        let files = try FileManager.default.contentsOfDirectory(atPath: r.url.path).sorted()
        #expect(
            r.url.lastPathComponent == "s_png"
                && files == ["s_00000.png", "s_00001.png", "s_00002.png", "s_00003.png", "s_00004.png", "s_00005.png"])
        let still = try ex.exportStill(
            scene: s, project: p, assets: nil, time: 0.1, to: dir.appendingPathComponent("still.png"))
        #expect(FileManager.default.fileExists(atPath: still.path))
    }
}
