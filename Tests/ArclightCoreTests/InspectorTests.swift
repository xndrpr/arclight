import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightEditor

@Suite struct ValuePathTests {
    @Test func settingNestedPaths() {
        let pool: JSONValue = ["pool": ["radius": 44, "color": "$fg"]]
        #expect(pool.setting(path: ["pool", "radius"], to: 60) == ["pool": ["radius": 60, "color": "$fg"]])
        #expect(pool.setting(path: ["pool", "radius"], to: nil) == ["pool": ["color": "$fg"]])
        // Missing parents are created; a `false` switch or number shorthand becomes an object.
        #expect(JSONValue.null.setting(path: ["from", "y"], to: 40) == ["from": ["y": 40]])
        #expect(JSONValue.bool(false).setting(path: ["radius"], to: 10) == ["radius": 10])
        #expect(JSONValue.number(0.5).setting(path: ["intensity"], to: 0.8) == ["intensity": 0.8])
        // Arrays by index.
        let items: JSONValue = [["symbol": "basic/dot"], ["symbol": "basic/star"]]
        #expect(
            items.setting(path: ["1", "height"], to: 80) == [
                ["symbol": "basic/dot"], ["symbol": "basic/star", "height": 80],
            ])
        #expect(items.setting(path: ["0"], to: nil) == [["symbol": "basic/star"]])
        #expect(items.value(at: ["1", "symbol"]) == "basic/star")
        #expect(pool.value(at: ["pool", "missing"]) == nil)
        #expect(pool.setting(path: [], to: 3) == 3)
    }

    @Test func constantAndExpressionProps() {
        let p = Prop.value(["radius": 44])
        #expect(p.setting(path: ["radius"], to: 50, at: 1) == .value(["radius": 50]))
        #expect(Prop.value(1).setting(path: [], to: 2, at: 0) == .value(2))
        #expect(Prop.value(1).setting(path: [], to: nil, at: 0) == nil)
        #expect(Prop.expr("t").setting(path: [], to: 3, at: 0) == .value(3))
    }

    @Test func keyframedObjectEditing() {
        let cam = Prop.keys([
            Keyframe(t: 0, v: ["fov": 40, "position": [0, 0, -100]]),
            Keyframe(t: 2, v: ["fov": 60, "position": [0, 0, -300]], ease: .named("inOutSine")),
        ])
        // On an existing key: edited in place.
        guard case .keys(let a)? = cam.setting(path: ["fov"], to: 45, at: 0) else { Issue.record("not keys"); return }
        #expect(a.count == 2 && a[0].v["fov"] == 45 && a[0].v["position"] == [0, 0, -100])
        // Between keys: a new key holding the interpolated object with the edit applied.
        guard case .keys(let b)? = cam.setting(path: ["fov"], to: 90, at: 1) else { Issue.record("not keys"); return }
        #expect(b.map(\.t) == [0, 1, 2])
        #expect(b[1].v["fov"] == 90)
        let z = b[1].v["position"]?.doubles?[2] ?? 0
        #expect(z < -100 && z > -300)  // interpolated with the easing
        #expect(b[1].ease == .named("inOutSine"))
        // Removing a nested field removes it from every key.
        guard case .keys(let c)? = cam.setting(path: ["fov"], to: nil, at: 1) else { Issue.record("not keys"); return }
        #expect(c.count == 2 && c.allSatisfy { $0.v["fov"] == nil })
        // Raw value keeps tokens and exact keys.
        let bg = Prop.keys([Keyframe(t: 0, v: "$bg"), Keyframe(t: 1, v: "$fg")])
        #expect(bg.rawValue(at: 0.5) == "$bg" && bg.rawValue(at: 1) == "$fg")
    }

    @Test func toggleKeyAndEase() {
        let p = Prop.value(["fov": 40])
        let k = p.togglingKey(at: 1, current: ["fov": 40])
        #expect(k == .keys([Keyframe(t: 1, v: ["fov": 40])]))
        #expect(k.togglingKey(at: 1, current: ["fov": 40]) == .value(["fov": 40]))
        let two = k.togglingKey(at: 2, current: ["fov": 50]).settingEase(.named("outExpo"), at: 2, fps: 30)
        guard case .keys(let ks) = two else { Issue.record("not keys"); return }
        #expect(ks.count == 2 && ks[1].ease == .named("outExpo"))
    }

    @Test func sceneHostProps() {
        var s = ArclightCore.Scene(id: "s", duration: 4)
        s.setProp(.scene, "post", .value(["grain": 0.05]))
        s.setProp(.scene, "duration", .value(6))
        s.setProp(.scene, "size", .value([1080, 1920]))
        #expect(s.post == .value(["grain": 0.05]) && s.duration == 6 && s.size == [1080, 1920])
        #expect(s.prop(.scene, "duration") == .value(6))
        s.setProp(.scene, "size", nil)
        #expect(s.size == nil)
    }
}

@Suite struct AnimationPresetTests {
    func text(_ props: [String: Prop] = [:]) -> Node {
        var p: [String: Prop] = ["text": .value("Hello"), "x": .value(100), "y": .value(200)]
        for (k, v) in props { p[k] = v }
        return Node(id: "t", type: "text", props: p)
    }

    func run(_ id: String, _ n: Node, at: Double) throws -> [String: Prop] {
        let p = try #require(AnimationPresets.preset(id))
        return p.make(n, at, 30)
    }

    @Test func fadeAndSlideIn() throws {
        let n = text()
        let fade = try run("fadeIn", n, at: 1)
        #expect(fade["opacity"] == .keys([Keyframe(t: 1, v: 0), Keyframe(t: 1.5, v: 1, ease: .named("outCubic"))]))
        let slide = try run("slideUp", n, at: 0)
        guard case .keys(let ys)? = slide["y"] else { Issue.record("y not keyed"); return }
        #expect(ys.first?.v == 260 && ys.last?.v == 200 && ys.last?.ease == .named("outExpo"))
        #expect(slide["opacity"]?.keyCount == 2)
    }

    @Test func presetsMergeWithExistingKeys() throws {
        let n = text(["opacity": .keys([Keyframe(t: 0, v: 0), Keyframe(t: 0.5, v: 1), Keyframe(t: 4, v: 1)])])
        let out = try run("fadeOut", n, at: 3.6)
        guard case .keys(let ks)? = out["opacity"] else { Issue.record("not keyed"); return }
        #expect(ks.map(\.t) == [0, 0.5, 3.6, 4])  // existing key at 4 replaced by the fade's end
        #expect(ks.last?.v == 0)
    }

    @Test func scalePopKeepsVectorScale() throws {
        let n = text(["scale": .value([2, 1])])
        let out = try run("scalePop", n, at: 0)
        guard case .keys(let ks)? = out["scale"] else { Issue.record("not keyed"); return }
        #expect(ks.first?.v == [0, 0] && ks.last?.v == [2, 1] && ks.last?.ease == .named("outBack"))
    }

    @Test func textPresets() throws {
        let n = text(["size": .value(80)])
        let mask = try run("maskReveal", n, at: 0.5)
        #expect(mask["reveal"]?.json["mask"] == true && mask["reveal"]?.json["by"] == "line")
        #expect(mask["reveal"]?.json["delay"] == 0.5 && mask["reveal"]?.json["from"]?["y"] == 88)
        let tw = try run("typewriter", n, at: 0)
        #expect(tw["reveal"]?.json["by"] == "char" && tw["reveal"]?.json["from"]?["y"] == 0)

        // Count up turns the number in the text into {v}.
        let stat = Node(id: "s", type: "text", props: ["text": .value("45% of people")])
        let count = try #require(AnimationPresets.preset("countUp"))
        #expect(count.applies(stat) && !count.applies(text()))
        let c = count(stat, at: 0, fps: 30)
        #expect(c["text"] == .value("{v}% of people"))
        #expect(c["value"] == .keys([Keyframe(t: 0, v: 0), Keyframe(t: 0.8, v: 45, ease: .named("outExpo"))]))
        // Text already with {v}: keeps the text, counts to the current value.
        let v = Node(id: "v", type: "text", props: ["text": .value("{v}%"), "value": .value(72)])
        let c2 = count(v, at: 1, fps: 30)
        #expect(c2["text"] == nil && c2["value"]?.keyCount == 2)
        guard case .keys(let ks)? = c2["value"] else { return }
        #expect(ks.last?.v == 72 && ks.first?.t == 1)
    }

    @Test func drawOnOnlyForLines() throws {
        let line = Node(id: "l", type: "shape", props: ["shape": .value("line")])
        let rect = Node(id: "r", type: "shape", props: ["shape": .value("rect")])
        let draw = try #require(AnimationPresets.preset("drawOn"))
        #expect(draw.applies(line) && !draw.applies(rect))
        #expect(
            draw(line, at: 0, fps: 30)["trim"]
                == .keys([Keyframe(t: 0, v: [0, 0]), Keyframe(t: 0.8, v: [0, 1], ease: .named("inOutCubic"))]))
    }

    @Test func emphasisAndTiming() throws {
        let n = text()
        let pulse = try run("pulse", n, at: 1)
        #expect(pulse["scale"]?.keyCount == 3)
        let shake = try run("shake", n, at: 0)
        guard case .keys(let ks)? = shake["x"] else { Issue.record("not keyed"); return }
        #expect(ks.first?.v == 100 && ks.last?.v == 100 && ks.count == 6)
        // Start times: snapped to frames; exits end at the out point.
        #expect(AnimationPresets.snap(1.01, 30) == 1)
        var timed = n; timed.start = 1; timed.end = 4
        let fadeOut = try #require(AnimationPresets.preset("fadeOut"))
        #expect(abs(AnimationPresets.startTime(fadeOut, node: timed, sceneTime: 2, sceneDuration: 5) - 2.6) < 1e-9)
        let fadeIn = try #require(AnimationPresets.preset("fadeIn"))
        #expect(AnimationPresets.startTime(fadeIn, node: timed, sceneTime: 0.5, sceneDuration: 5) == 0)
        #expect(AnimationPresets.startTime(fadeIn, node: timed, sceneTime: 2, sceneDuration: 5) == 1)
        // Every preset produces something for a layer it applies to.
        let line = Node(id: "l", type: "shape", props: ["shape": .value("line")])
        for p in AnimationPresets.all {
            let target = p.applies(n) ? n : line
            guard p.applies(target) else { continue }
            #expect(!p(target, at: 0, fps: 30).isEmpty, "\(p.id)")
            #expect((0.4...0.8).contains(p.duration), "\(p.id)")
        }
    }
}

@Suite(.serialized) struct InspectorDocumentTests {
    func makeDoc() throws -> (EditorDocument, URL) {
        var s = ArclightCore.Scene(id: "s", duration: 4)
        s.camera = .keys([
            Keyframe(t: 0, v: ["fov": 40, "shake": [["at": 1]]]), Keyframe(t: 2, v: ["fov": 60, "shake": [["at": 1]]]),
        ])
        s.nodes = [Node(id: "crowd", type: "repeater", props: ["pool": .value(["radius": 44])])]
        let (doc, project) = try ArclightCoreTests.makeDoc(scene: s)
        return (doc, project.url)
    }

    @Test(.requiresMetal) func nestedWritesThroughSlots() throws {
        let (doc, dir) = try makeDoc()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pool = try #require(Schema.field("repeater", "pool"))
        guard case .object(let ps) = pool.kind, let radius = ps.field("radius") else { Issue.record("schema"); return }
        let r = doc.child(doc.slot(.node("crowd"), "pool", field: pool), radius)
        #expect(r.stored == 44 && r.isSet && !r.isTop)
        doc.write(r, 60)
        #expect(doc.scene.node("crowd")?.props["pool"] == .value(["radius": 60]))
        // Absent field: not set (the inspector shows the default greyed).
        let cone = try #require(Schema.field("repeater", "cone"))
        #expect(!doc.slot(.node("crowd"), "cone", field: cone).isSet)

        // Keyframed scene camera: a field edit between keys inserts a key at the playhead.
        let camField = try #require(Schema.sceneFields.first { $0.name == "camera" })
        let fovField = try #require(Schema.camera.field("fov"))
        doc.time = 1
        let fov = doc.child(doc.slot(.scene, "camera", field: camField), fovField)
        #expect(fov.rootAnimated && fov.stored == 50)
        doc.write(fov, 70)
        guard case .keys(let ks)? = doc.scene.camera else { Issue.record("camera not keyed"); return }
        #expect(ks.map(\.t) == [0, 1, 2] && ks[1].v["fov"] == 70)
        // Lists inside a keyframed object change in every key.
        let shakeField = try #require(Schema.camera.field("shake"))
        let shake = doc.child(doc.slot(.scene, "camera", field: camField), shakeField)
        doc.write(shake, [["at": 3]])
        guard case .keys(let ks2)? = doc.scene.camera else { return }
        #expect(ks2.allSatisfy { $0.v["shake"] == [["at": 3]] })
        // Key navigation and removing animation for scene props.
        doc.jumpKey(in: .scene, "camera", forward: true)
        #expect(doc.time == 2)
        doc.clearAnimation(in: .scene, "camera")
        #expect(doc.scene.camera?.keyCount == 0)
    }

    /// A number keyframed inside a layer's object setting (`pool.intensity: {"k": …}`) shows its value at the
    /// playhead, and a drag can't replace its keyframes; plain numbers next to it are edited as before.
    @Test(.requiresMetal) func numberKeyframedInsideAnObjectIsReadOnly() throws {
        let keys: JSONValue = ["k": [[0, 0], [2, 1.2]]]
        var s = ArclightCore.Scene(id: "s", duration: 4)
        s.nodes = [
            Node(id: "lamp", type: "light", props: ["pool": .value(["radius": 200, "intensity": keys])]),
            Node(
                id: "keyed", type: "light",
                props: ["pool": .keys([Keyframe(t: 0, v: ["intensity": 0.5]), Keyframe(t: 2, v: ["intensity": 1])])]),
        ]
        let (doc, project) = try ArclightCoreTests.makeDoc(scene: s)
        defer { try? FileManager.default.removeItem(at: project.url) }
        let pool = try #require(Schema.field("light", "pool"))
        guard case .object(let ps) = pool.kind, let intensity = ps.field("intensity"), let radius = ps.field("radius")
        else { Issue.record("schema"); return }
        doc.time = 1
        let i = doc.child(doc.slot(.node("lamp"), "pool", field: pool), intensity)
        #expect(i.keyedInside && i.stored == 0.6 && i.isSet)
        #expect(doc.evaluated(i) == 0.6)
        doc.scrub(i, 0.3, .began); doc.scrub(i, 0.3, .changed); doc.scrub(i, 0.3, .ended)
        #expect(doc.scene.node("lamp")?.props["pool"] == .value(["radius": 200, "intensity": keys]))
        // Plain numbers, and numbers inside a keyframed object, are unchanged.
        let r = doc.child(doc.slot(.node("lamp"), "pool", field: pool), radius)
        #expect(!r.keyedInside && r.stored == 200)
        let k = doc.child(doc.slot(.node("keyed"), "pool", field: pool), intensity)
        #expect(!k.keyedInside && k.stored == 0.75 && k.rootAnimated)
        // The same rule as the evaluator: only animatable number settings qualify.
        #expect(Schema.nestedKeys(type: "light", prop: "pool", key: "intensity", keys)?.count == 2)
        #expect(Schema.nestedKeys(type: "light", prop: "pool", key: "color", keys) == nil)
        #expect(Schema.nestedKeys(type: "text", prop: "text", key: "x", keys) == nil)
    }

    @Test func symbolPreviewPaths() {
        #expect(Symbols.previewPath("basic/person") != nil)
        #expect(Symbols.previewPath("chess/knight") != nil)
        #expect(Symbols.previewPath("nope/none") == nil)
        #expect(Symbols.previewUsesEvenOdd("basic/coin"))
    }
}
