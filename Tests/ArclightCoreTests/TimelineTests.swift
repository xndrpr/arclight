import AVFoundation
import Foundation
import Testing

@testable import ArclightCore
@testable import ArclightEditor

/// Timeline editing logic: trim start, keyframe selection edits, markers, audio clip geometry, loop playback.
@Suite(.serialized) struct TimelineTests {
    typealias S = ArclightCore.Scene

    /// title: in 1, keys on opacity (local 0, 0.5) and x (local 0.5, 2), reveal delay 0.2; fx: expression.
    func scene() -> S {
        var s = S(id: "s", duration: 6)
        var title = Node(
            id: "title", type: "text",
            props: [
                "opacity": .keys([Keyframe(t: 0, v: 0), Keyframe(t: 0.5, v: 1, ease: .named("outExpo"))]),
                "x": .keys([Keyframe(t: 0.5, v: 100), Keyframe(t: 2, v: 300)]),
                "reveal": .value(["by": "char", "delay": 0.2]),
                "text": .value("Hi"),
            ])
        title.start = 1; title.end = 5
        var fx = Node(id: "fx", type: "shape", props: ["x": .expr("t * 10")])
        fx.start = 0.5
        s.nodes = [title, fx]
        return s
    }

    func keys(_ s: S, _ id: String, _ p: String) -> [Double] {
        if case .keys(let ks)? = s.node(id)?.props[p] { return ks.map(\.t) }
        return []
    }

    // MARK: Trim start

    @Test func trimStartKeepsContentInPlace() throws {
        let s = scene()
        let r = TimelineEdit.trimStart(s, id: "title", to: 1.5)
        #expect(!r.usesExpressions)
        let n = try #require(r.scene.node("title"))
        #expect(n.start == 1.5 && n.end == 5)
        #expect(keys(r.scene, "title", "opacity") == [-0.5, 0])  // scene times 1, 1.5 unchanged
        #expect(keys(r.scene, "title", "x") == [0, 1.5])
        #expect(n.props["reveal"] == .value(["by": "char", "delay": -0.3]))
        #expect(n.props["text"] == .value("Hi"))
        // Evaluated values at a scene time are identical.
        let ev = Evaluator()
        for T in [1.6, 2.0, 2.9] {
            let after = ev.evaluate(r.scene, T: T).first(where: { $0.node.id == "title" })?.props["x"]
            let before = ev.evaluate(s, T: T).first(where: { $0.node.id == "title" })?.props["x"]
            #expect(after != nil && after == before)
        }
        // Trimming back to the original start restores the scene; to 0 clears `in`.
        #expect(TimelineEdit.trimStart(r.scene, id: "title", to: 1).scene == s)
        let z = TimelineEdit.trimStart(s, id: "title", to: 0).scene
        #expect(z.node("title")?.start == nil && keys(z, "title", "x") == [1.5, 3])
        // Expressions can't be shifted: reported.
        #expect(TimelineEdit.trimStart(s, id: "fx", to: 1).usesExpressions)
        // A layer without a reveal gets none.
        #expect(TimelineEdit.trimStart(s, id: "fx", to: 1).scene.node("fx")?.props["reveal"] == nil)
    }

    // MARK: Keyframes

    @Test func keySelectionRefsMoveAndCollide() {
        let s = scene()
        // The layer-row diamond at scene 1.5 covers opacity@0.5 and x@0.5; the prop row only its own key.
        let both = KeyEdit.refs(s, node: "title", prop: nil, at: 1.5)
        #expect(both == [KeyRef(node: "title", prop: "opacity", t: 0.5), KeyRef(node: "title", prop: "x", t: 0.5)])
        #expect(KeyEdit.refs(s, node: "title", prop: "x", at: 1.5) == [KeyRef(node: "title", prop: "x", t: 0.5)])
        #expect(KeyEdit.refs(s, node: "title", prop: nil, in: 0.9...3.1).count == 4)
        // Move by +0.25: refs follow.
        let m = KeyEdit.move(s, both, by: 0.25)
        #expect(keys(m.scene, "title", "opacity") == [0, 0.75] && keys(m.scene, "title", "x") == [0.75, 2])
        #expect(m.refs == [KeyRef(node: "title", prop: "opacity", t: 0.75), KeyRef(node: "title", prop: "x", t: 0.75)])
        // Easing travels with the key.
        if case .keys(let ks)? = m.scene.node("title")?.props["opacity"] { #expect(ks[1].ease == .named("outExpo")) }
        // Landing on an unmoved key replaces it.
        let c = KeyEdit.move(s, [KeyRef(node: "title", prop: "x", t: 0.5)], by: 1.5)
        #expect(keys(c.scene, "title", "x") == [2])
        if case .keys(let ks)? = c.scene.node("title")?.props["x"] { #expect(ks[0].v == 100) }
        // Clamped at scene time 0 (layer starts at 1 → local −1).
        let early = KeyEdit.move(s, [KeyRef(node: "title", prop: "opacity", t: 0)], by: -5)
        #expect(keys(early.scene, "title", "opacity") == [-1, 0.5])
        // Stale refs are ignored.
        #expect(KeyEdit.existing(s, [KeyRef(node: "title", prop: "x", t: 9)]).isEmpty)
    }

    @Test func keyDeleteNudgeEaseCopyPaste() {
        let s = scene()
        let x05 = KeyRef(node: "title", prop: "x", t: 0.5)
        // Delete one key; deleting all keys leaves a constant.
        #expect(keys(KeyEdit.delete(s, [x05]), "title", "x") == [2])
        let gone = KeyEdit.delete(s, [x05, KeyRef(node: "title", prop: "x", t: 2)])
        #expect(gone.node("title")?.props["x"] == .value(100))
        // Nudge by one frame at 30 fps.
        let n = KeyEdit.move(s, [x05], by: 1.0 / 30)
        #expect(abs(keys(n.scene, "title", "x")[0] - (0.5 + 1.0 / 30)) < 1e-6)
        // Ease.
        let e = KeyEdit.setEase(s, [x05], .named("spring"))
        #expect(KeyEdit.commonEase(e, [x05]) == "spring")
        #expect(KeyEdit.commonEase(s, [x05, KeyRef(node: "title", prop: "opacity", t: 0.5)]) == nil)
        #expect(KeyEdit.commonEase(KeyEdit.setEase(e, [x05], nil), [x05]) == "linear")
        // Copy two keys (scene 1.5 and 3) and paste at 4: keeps spacing, onto the same layer.
        let clip = KeyEdit.copy(s, [x05, KeyRef(node: "title", prop: "x", t: 2)])!
        #expect(clip.items.map(\.dt) == [0, 1.5])
        let p = KeyEdit.paste(s, clip, at: 4)
        #expect(keys(p.scene, "title", "x") == [0.5, 2, 3, 4.5])
        #expect(p.refs.count == 2)
        // Paste onto another layer: a constant becomes animated, expressions are skipped.
        var s2 = s
        s2.nodes.append(Node(id: "box", type: "shape", props: ["x": .value(5)]))
        let q = KeyEdit.paste(s2, clip, at: 1, target: "box")
        #expect(keys(q.scene, "box", "x") == [1, 2.5])
        #expect(KeyEdit.paste(s, clip, at: 1, target: "fx").refs.isEmpty)
    }

    @Test(.requiresMetal) func documentKeyCommandsNeedTimelineFocus() throws {
        let (doc, project) = try makeDoc(scene: scene())
        defer { project.remove() }
        let x05 = KeyRef(node: "title", prop: "x", t: 0.5)
        doc.timelineUI.selectedKeys = [x05]
        doc.timelineUI.focused = false
        #expect(!doc.deleteSelectedKeys())  // ⌫ falls through to deleting the layer
        doc.timelineUI.focused = true
        #expect(doc.nudgeSelectedKeys(3))
        #expect(abs(keys(doc.scene, "title", "x")[0] - 0.6) < 1e-6)
        #expect(doc.timelineUI.selectedKeys.first?.t == keys(doc.scene, "title", "x")[0])
        #expect(doc.deleteSelectedKeys())
        #expect(keys(doc.scene, "title", "x") == [2])
        #expect(doc.timelineUI.selectedKeys.isEmpty && !doc.deleteSelectedKeys())
        // Markers: M adds marker-1, marker-2…; snapping includes markers.
        doc.time = 2
        doc.addMarkerAtPlayhead()
        doc.time = 3
        doc.addMarkerAtPlayhead()
        #expect(doc.scene.markers?.map(\.name) == ["marker-1", "marker-2"])
        #expect(doc.snapTime(3.05, tolerance: 0.1) == 3)
        doc.time = 0
        #expect(doc.snapTime(2.04, tolerance: 0.1) == 2)
        doc.updateMarker("marker-1", rename: "hit")
        doc.updateMarker("hit", color: .some("#EE5454"))
        #expect(doc.scene.marker("hit")?.t == 2 && doc.scene.marker("hit")?.color == "#EE5454")
        doc.updateMarker("hit", rename: "marker-2")  // name taken: refused
        #expect(doc.scene.marker("hit") != nil)
        doc.removeMarker("hit")
        #expect(doc.scene.markers?.map(\.name) == ["marker-2"])
        doc.toggleLoop()
        #expect(!doc.loopEnabled)
    }

    // MARK: Markers

    @Test func markerNamesAndOps() throws {
        var s = scene()
        #expect(MarkerEdit.nextName(s) == "marker-1")
        s = try SceneOps.apply(
            [MarkerEdit.addOp("marker-1", t: 1), MarkerEdit.addOp("marker-3", t: 2, color: "#5C99FA")], to: s
        ).scene
        #expect(MarkerEdit.nextName(s) == "marker-2")
        let m3 = s.marker("marker-3")!
        // Move keeps colour; rename keeps time and colour.
        s = try SceneOps.apply(MarkerEdit.updateOps(m3, t: 0.5), to: s).scene
        #expect(s.markers?.map(\.name) == ["marker-3", "marker-1"] && s.marker("marker-3")?.color == "#5C99FA")
        s = try SceneOps.apply(MarkerEdit.updateOps(s.marker("marker-3")!, name: "beat"), to: s).scene
        #expect(s.marker("marker-3") == nil && s.marker("beat") == Marker(name: "beat", t: 0.5, color: "#5C99FA"))
        s = try SceneOps.apply(MarkerEdit.updateOps(s.marker("beat")!, color: .some(nil)), to: s).scene
        #expect(s.marker("beat")?.color == nil)
        #expect(MarkerEdit.expression("beat") == "marker(\"beat\")")
        // Label truncation: 6 pt per character.
        #expect(MarkerStyle.fit("marker-12", room: 100) { CGFloat($0.count * 6) } == "marker-12")
        #expect(MarkerStyle.fit("marker-12", room: 30) { CGFloat($0.count * 6) } == "mark…")
        #expect(MarkerStyle.fit("marker-12", room: 10) { CGFloat($0.count * 6) } == nil)
    }

    // MARK: Audio

    @Test func audioClipGeometryAndSchedule() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arclight-tla-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("vo.wav")
        try tone(wav, seconds: 4)
        let info = try #require(SceneAudio.info(wav))
        var a = AudioRef(src: "vo.wav"); a.offset = 1; a.trim = 0.5; a.gain = 0.5; a.fadeIn = 1; a.fadeOut = 0.5
        let c = AudioClip(a, fileDuration: info.duration, sceneDuration: 3)
        #expect(c.start == 1 && abs(c.end - 4.5) < 1e-6 && c.audibleEnd == 3)
        #expect(abs(c.filePosition(at: 2) - 1.5) < 1e-9)
        // Envelope: silent before the clip, fading in over 1 s, full gain, fading out to the scene end.
        #expect(c.envelope(at: 0.5) == 0)
        #expect(abs(c.envelope(at: 1.5) - 0.25) < 1e-9)
        #expect(abs(c.envelope(at: 2.2) - 0.5) < 1e-9)
        #expect(abs(c.envelope(at: 2.75) - 0.25) < 1e-9)
        #expect(c.envelope(at: 3) == 0)
        // Playback from 0: wait 1 s, read from file 0.5 s, play 2 s (cut at the scene end).
        #expect(c.segment(from: 0, until: 3) == .init(fileStart: 0.5, delay: 1, duration: 2))
        // From 2 inside a work area ending at 2.5.
        let seg = try #require(c.segment(from: 2, until: 2.5))
        #expect(abs(seg.fileStart - 1.5) < 1e-9 && seg.delay == 0 && abs(seg.duration - 0.5) < 1e-9)
        #expect(c.segment(from: 3.2, until: 3) == nil)
        let fr = try #require(AudioClip.frames(seg, sampleRate: 48000, fileFrames: 4 * 48000))
        #expect(fr.start == 72000 && fr.count == 24000)
        #expect(
            AudioClip.frames(.init(fileStart: 3.9, delay: 0, duration: 1), sampleRate: 48000, fileFrames: 4 * 48000)?
                .count == 4800)
        // Negative offset: head cut by the scene start.
        var b = AudioRef(src: "vo.wav"); b.offset = -1
        let nc = AudioClip(b, fileDuration: 4, sceneDuration: 10)
        #expect(nc.segment(from: 0, until: 10) == .init(fileStart: 1, delay: 0, duration: 3))
        // Trimming the head keeps content in place; clamped at trim 0 and before the end.
        let t1 = c.trimmedStart(to: 1.5)
        #expect(t1.offset == 1.5 && t1.trim == 1)
        var moved = a; moved.offset = t1.offset; moved.trim = t1.trim
        #expect(
            abs(AudioClip(moved, fileDuration: 4, sceneDuration: 3).filePosition(at: 2) - c.filePosition(at: 2)) < 1e-9)
        #expect(c.trimmedStart(to: -5) == (offset: 0.5, trim: 0))
        #expect(abs(c.trimmedStart(to: 99).offset - (4.5 - 0.05)) < 1e-9)
        #expect(c.moved(to: 2) == (offset: 2, trim: 0.5))
        // Gain mapping: middle = 1 (0 dB), top = 2.
        #expect(
            AudioClip.gain(fromUnitY: 0.5) == 1 && AudioClip.gain(fromUnitY: 1.2) == 2
                && AudioClip.unitY(gain: 0.5) == 0.25)
        #expect(AudioClip.dB(1) == "+0.0 dB" && AudioClip.dB(0.5) == "−6.0 dB")
    }

    // MARK: Loop

    @Test func loopPlayback() {
        let L = PlaybackLoop.self
        // Whole scene, loop on: wraps.
        #expect(abs(L.advance(4.9, by: 0.2, duration: 5, loop: true, range: nil).t - 0.1) < 1e-9)
        // Loop off: stops at the end; pressing play at the end starts over.
        #expect(L.advance(4.9, by: 0.2, duration: 5, loop: false, range: nil) == (5, true))
        #expect(L.advance(5, by: 0.02, duration: 5, loop: false, range: nil) == (0, false))
        // Work area 1…2: wraps inside it; playing into it from before is fine; past it jumps to its start.
        let w = 1.0...2.0
        #expect(abs(L.advance(1.95, by: 0.1, duration: 5, loop: true, range: w).t - 1.05) < 1e-9)
        #expect(abs(L.advance(0.5, by: 0.1, duration: 5, loop: true, range: w).t - 0.6) < 1e-9)
        #expect(L.advance(3, by: 0.02, duration: 5, loop: true, range: w) == (1, false))
        #expect(L.advance(1.95, by: 0.1, duration: 5, loop: false, range: w) == (2, true))
        // Reverse (J): wraps to the end of the range.
        #expect(abs(L.advance(1.05, by: -0.1, duration: 5, loop: true, range: w).t - 1.95) < 1e-9)
        #expect(abs(L.advance(0.05, by: -0.1, duration: 5, loop: true, range: nil).t - 4.95) < 1e-9)
        // Degenerate range falls back to the scene.
        #expect(abs(L.advance(4.9, by: 0.2, duration: 5, loop: true, range: 2...2).t - 0.1) < 1e-9)
    }
}
