import AppKit
import Foundation
import Testing
import simd

@testable import ArclightCore
@testable import ArclightEditor

/// Canvas tools: zoom/pan, rulers, snapping, handles, anchor compensation, align/distribute, selection,
/// 3D picking and camera orbit (pure geometry), plus the document commands built on them.
@Suite(.serialized) struct CanvasTests {
    func near(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 1e-6) -> Bool { abs(a - b) <= eps }
    func near(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) <= eps }
    func near(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ eps: Float = 1e-2) -> Bool { simd_length(a - b) <= eps }

    // MARK: Zoom & pan

    @Test func fitLetterboxesAndZoomKeepsPointUnderPointer() {
        let canvas = CGSize(width: 1920, height: 1080), view = CGSize(width: 1000, height: 800)
        #expect(near(ViewZoom.fit(canvas: canvas, view: view, pad: 20), 960 / 1920))
        let s0: CGFloat = 0.5, s1: CGFloat = 2, pan0 = CGSize(width: 30, height: -12)
        let pointer = CGPoint(x: 710, y: 260)  // viewport coords
        let before = ViewZoom.canvasPoint(pointer, view: view, canvas: canvas, scale: s0, pan: pan0)
        let rel = CGPoint(x: pointer.x - view.width / 2, y: pointer.y - view.height / 2)
        let pan1 = ViewZoom.pan(zoomingFrom: s0, to: s1, at: rel, pan: pan0)
        let after = ViewZoom.canvasPoint(pointer, view: view, canvas: canvas, scale: s1, pan: pan1)
        #expect(near(before.x, after.x, 1e-6) && near(before.y, after.y, 1e-6))
        // Centre of the viewport at no pan = canvas centre.
        let c = ViewZoom.canvasPoint(CGPoint(x: 500, y: 400), view: view, canvas: canvas, scale: 0.5, pan: .zero)
        #expect(near(c.x, 960) && near(c.y, 540))
        #expect(ViewZoom.clamp(100) == ViewZoom.maxScale && ViewZoom.clamp(0) == ViewZoom.minScale)
        let p = ViewZoom.clampPan(
            CGSize(width: 99999, height: -99999), canvas: CGSize(width: 400, height: 200), view: view)
        #expect(p.width == 700 - 40 && p.height == -(500 - 40))
        #expect(ViewZoom.label(0.5) == "50%" && ViewZoom.label(2) == "200%")
    }

    @Test func viewportStateZoomAndFit() {
        let vp = ViewportState()
        vp.viewSize = CGSize(width: 1000, height: 600); vp.canvas = CGSize(width: 1920, height: 1080); vp.pad = 24
        #expect(vp.isFit && near(vp.scale, vp.fitScale))
        let pointer = CGPoint(x: 800, y: 150)
        let before = vp.canvasPoint(pointer)
        vp.zoom(by: 3, at: pointer)
        #expect(!vp.isFit && near(vp.scale, vp.fitScale * 3, 1e-9))
        let after = vp.canvasPoint(pointer)
        #expect(near(before.x, after.x, 1e-6) && near(before.y, after.y, 1e-6))
        vp.fit()
        #expect(vp.isFit && vp.pan == .zero)
        vp.setScale(1)
        #expect(vp.scale == 1)
    }

    @Test func rulerStepsAreNiceAndTicksCoverRange() {
        #expect(RulerMath.step(scale: 1) == 100)  // 60 px → 100
        #expect(RulerMath.step(scale: 0.5) == 200)  // 120 px → 200
        #expect(RulerMath.step(scale: 0.25) == 500)  // 240 → 500
        #expect(RulerMath.step(scale: 4) == 20)  // 15 → 20
        #expect(RulerMath.step(scale: 8) == 10)  // 7.5 → 10
        #expect(RulerMath.ticks(from: -30, to: 250, step: 100) == [0, 100, 200])
        #expect(RulerMath.ticks(from: 0, to: 1e9, step: 1).isEmpty)  // too many: drawn as nothing
    }

    @Test func guidesSafeAreasAndThirds() {
        let c = CGSize(width: 1920, height: 1080)
        #expect(CanvasGuides.safe(c, fraction: 0.9) == CGRect(x: 96, y: 54, width: 1728, height: 972))
        #expect(CanvasGuides.safe(c, fraction: 0.8) == CGRect(x: 192, y: 108, width: 1536, height: 864))
        #expect(CanvasGuides.thirds(c).xs == [640, 1280] && CanvasGuides.thirds(c).ys == [360, 720])
    }

    // MARK: Snapping

    @Test func snapToCanvasCentreAndOtherLayers() {
        let canvas = CGSize(width: 1000, height: 500)
        let (xs, ys) = Snap.targets(canvas: canvas, others: [CGRect(x: 100, y: 100, width: 50, height: 50)])
        // centre, other's edge, safe
        #expect(xs.contains(500) && xs.contains(150) && xs.contains(50) && ys.contains(125))
        // A 100-wide box whose centre is at 503: snaps 3 px left to the canvas centre.
        var r = Snap.snap(CGRect(x: 453, y: 300, width: 100, height: 40), xs: xs, ys: ys, threshold: 6)
        #expect(r.offset.width == -3 && r.lines.contains(SnapLine(axis: .x, value: 500)))
        // Top edge 2 px under the other layer's bottom edge (150).
        r = Snap.snap(CGRect(x: 700, y: 152, width: 10, height: 10), xs: [], ys: ys, threshold: 6)
        #expect(r.offset.height == -2 && r.lines == [SnapLine(axis: .y, value: 150)])
        // Nothing near: no snap.
        r = Snap.snap(CGRect(x: 300, y: 300, width: 10, height: 10), xs: [0, 1000], ys: [0], threshold: 6)
        #expect(r.offset == .zero && r.lines.isEmpty)
        // Closest target wins.
        #expect(Snap.best([10], [14, 8], threshold: 6)?.at == 8)
    }

    // MARK: Handles

    @Test func handlesAndScaleFactors() {
        let q = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 50), CGPoint(x: 0, y: 50)]
        #expect(Handle.top.point(on: q) == CGPoint(x: 50, y: 0) && Handle.left.point(on: q) == CGPoint(x: 0, y: 25))
        #expect(Handle.topLeft.opposite == .bottomRight && Handle.right.opposite == .left)
        #expect(Handle.allCases.filter(\.isCorner).count == 4)
        // Corner, free: both axes follow the pointer.
        var f = TransformMath.scaleFactors(
            handle: .bottomRight, v0: CGPoint(x: 50, y: 25), v: CGPoint(x: 100, y: 25), uniform: false)
        #expect(f.x == 2 && f.y == 1)
        // Corner, ⇧: uniform (projection onto the diagonal).
        f = TransformMath.scaleFactors(
            handle: .bottomRight, v0: CGPoint(x: 50, y: 25), v: CGPoint(x: 100, y: 50), uniform: true)
        #expect(near(f.x, 2) && near(f.y, 2))
        // Side: one axis only.
        f = TransformMath.scaleFactors(
            handle: .right, v0: CGPoint(x: 50, y: 25), v: CGPoint(x: 75, y: 80), uniform: false)
        #expect(f.x == 1.5 && f.y == 1)
        f = TransformMath.scaleFactors(
            handle: .top, v0: CGPoint(x: 0, y: -25), v: CGPoint(x: 30, y: -50), uniform: false)
        #expect(f.x == 1 && f.y == 2)
        // Degenerate grab (on the origin) doesn't explode.
        f = TransformMath.scaleFactors(handle: .right, v0: .zero, v: CGPoint(x: 10, y: 0), uniform: false)
        #expect(f.x == 1)
        #expect(TransformMath.scaleValue(1.2, 1.2, wasArray: false) == .number(1.2))
        #expect(TransformMath.scaleValue(1.2, 0.5, wasArray: false) == [.number(1.2), .number(0.5)])
        #expect(TransformMath.scaleParts([.number(2), .number(3)]).1 == 3 && TransformMath.scaleParts(nil).0 == 1)
    }

    @Test func rotateHandleSitsAboveTheBox() {
        let q = [CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 150), CGPoint(x: 0, y: 150)]
        #expect(GizmoLayout.rotateHandle(q) == CGPoint(x: 50, y: 100 - GizmoLayout.rotateOffset))
        // Box rotated 90° clockwise: its "up" now points to +x.
        let r = [CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 100), CGPoint(x: 0, y: 100), CGPoint(x: 0, y: 0)]
        let h = GizmoLayout.rotateHandle(r)
        #expect(near(h.x, 50 + GizmoLayout.rotateOffset) && near(h.y, 50))
    }

    @Test func rotationFollowsPointerAndSnaps() {
        let pivot = CGPoint(x: 0, y: 0)
        // Pointer from straight up (−y) to the right (+x): +90° (clockwise on a y-down canvas).
        #expect(
            near(
                TransformMath.rotation(
                    start: 10, pivot: pivot, from: CGPoint(x: 0, y: -10), to: CGPoint(x: 10, y: 0), snap: false), 100))
        #expect(
            TransformMath.rotation(
                start: 0, pivot: pivot, from: CGPoint(x: 10, y: 0), to: CGPoint(x: 10, y: 2.2), snap: true) == 15)
        // Crossing ±180° doesn't jump a full turn.
        let r = TransformMath.rotation(
            start: 0, pivot: pivot, from: CGPoint(x: -10, y: -0.1), to: CGPoint(x: -10, y: 0.1), snap: false)
        #expect(abs(r) < 2)
    }

    @Test func anchorCompensationKeepsTheLayerInPlace() {
        let props: [String: JSONValue] = [
            "x": 300, "y": 200, "rotation": 30, "scale": [.number(1.5), .number(0.75)], "anchor": [10, 5],
        ]
        let before = Evaluator.localMatrix(props)
        let r = TransformMath.compensate(
            x: 300, y: 200, rotation: 30, scale: (1.5, 0.75),
            anchor: CGPoint(x: 10, y: 5), to: CGPoint(x: 60, y: -20))
        var p2 = props
        p2["x"] = .number(r.x); p2["y"] = .number(r.y); p2["anchor"] = [60, -20]
        let after = Evaluator.localMatrix(p2)
        for pt in [SIMD4<Float>(0, 0, 0, 1), SIMD4<Float>(100, 40, 0, 1), SIMD4<Float>(-30, 70, 0, 1)] {
            let a = before * pt, b = after * pt
            #expect(abs(a.x - b.x) < 1e-3 && abs(a.y - b.y) < 1e-3)
        }
    }

    // MARK: Align & distribute

    @Test func alignAndDistribute() {
        let rs = [
            CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 50, y: 20, width: 30, height: 10),
            CGRect(x: 200, y: 5, width: 20, height: 40),
        ]
        #expect(Align.offsets(rs, .left).map(\.width) == [0, -50, -200])
        #expect(Align.offsets(rs, .right).map(\.width) == [210, 140, 0])
        #expect(Align.offsets(rs, .hCenter).map(\.width) == [105, 45, -100])
        #expect(Align.offsets(rs, .top).map(\.height) == [0, -20, -5])
        #expect(Align.offsets(rs, .bottom).map(\.height) == [35, 15, 0])
        #expect(Align.offsets(rs, .vMiddle).map(\.height) == [17.5, -2.5, -2.5])
        // One rect aligned to the canvas.
        #expect(
            Align.offsets([rs[1]], .hCenter, to: CGRect(x: 0, y: 0, width: 1000, height: 500)) == [
                CGSize(width: 435, height: 0)
            ])
        // Distribute: total span 220, widths 60 → gap 80; outermost stay.
        let d = Align.offsets(rs, .distributeH)
        #expect(d.map(\.width) == [0, 40, 0] && d.allSatisfy { $0.height == 0 })
        // Order follows position, not input order.
        let shuffled = [rs[2], rs[0], rs[1]]
        #expect(Align.offsets(shuffled, .distributeH).map(\.width) == [0, 0, 40])
        #expect(Align.offsets(Array(rs.prefix(2)), .distributeV) == [.zero, .zero])
    }

    // MARK: Selection

    @Test func shiftClickTogglesSelection() {
        var r = CanvasSelection.toggle("b", primary: "a", extras: [])
        #expect(r.primary == "b" && r.extras == ["a"])
        r = CanvasSelection.toggle("a", primary: r.primary, extras: r.extras)
        #expect(r.primary == "b" && r.extras.isEmpty)
        r = CanvasSelection.toggle("b", primary: "b", extras: ["c"])
        #expect(r.primary == "c" && r.extras.isEmpty)
        r = CanvasSelection.toggle("z", primary: nil, extras: [])
        #expect(r.primary == "z" && r.extras.isEmpty)
        r = CanvasSelection.toggle("z", primary: "z", extras: [])
        #expect(r.primary == nil)
    }

    // MARK: 3D

    @Test func cameraRayMatchesProjection() {
        let w: Float = 1920, h: Float = 1080
        let cams: [JSONValue?] = [
            nil, ["position": [400, -600, -900], "target": [960, 540, 300], "fov": 50],
            ["position": [1500, 200, -1200], "target": [700, 600, 0], "roll": 12],
        ]
        for json in cams {
            let cam = CameraState.make(json, width: w, height: h)
            for p in [SIMD3<Float>(960, 540, 0), SIMD3<Float>(200, 800, 400), SIMD3<Float>(1500, 300, -100)] {
                let c = cam.viewProj * SIMD4<Float>(p, 1)
                guard c.w > 0 else { continue }
                let px = SIMD2((c.x / c.w + 1) / 2 * w, (1 - c.y / c.w) / 2 * h)
                let ray = cam.ray(at: px, width: w, height: h)
                // The point lies on the ray: distance from the ray line ≈ 0.
                let v = p - ray.origin
                let off = v - simd_dot(v, ray.dir) * ray.dir
                #expect(simd_length(off) < 0.5, "camera \(String(describing: json)) point \(p)")
            }
        }
        // Default camera: the canvas centre looks straight ahead and z = 0 maps 1:1 to the canvas.
        let d = CameraState.make(nil, width: w, height: h)
        let r = d.ray(at: SIMD2(100, 200), width: w, height: h)
        let hit = r.origin + r.dir * ((0 - r.origin.z) / r.dir.z)
        #expect(abs(hit.x - 100) < 0.05 && abs(hit.y - 200) < 0.05)
    }

    @Test func rayPlaneOrbitAndDolly() {
        #expect(Space3D.hitPlane(origin: SIMD3(0, -100, 0), dir: SIMD3(0, 1, 0), planeY: 50) == SIMD3(0, 50, 0))
        #expect(Space3D.hitPlane(origin: SIMD3(0, -100, 0), dir: SIMD3(1, 0, 0), planeY: 50) == nil)  // parallel
        #expect(Space3D.hitPlane(origin: SIMD3(0, -100, 0), dir: SIMD3(0, -1, 0), planeY: 50) == nil)  // behind
        let t = SIMD3<Float>(960, 540, 0), eye = SIMD3<Float>(960, 540, -1000)
        // Yaw a quarter turn: still 1000 away, same height, moved to the side.
        let e1 = Space3D.orbit(eye: eye, target: t, yaw: .pi / 2, pitch: 0)
        #expect(abs(simd_length(e1 - t) - 1000) < 0.1 && abs(e1.y - 540) < 0.01 && abs(abs(e1.x - 960) - 1000) < 0.1)
        // Pitch is clamped short of straight overhead (y down: above = smaller y).
        let e2 = Space3D.orbit(eye: eye, target: t, yaw: 0, pitch: 3)
        #expect(e2.y < 540 && abs(simd_length(e2 - t) - 1000) < 0.1 && abs(e2.z - t.z) > 50)
        #expect(near(Space3D.dolly(eye: eye, target: t, factor: 0.5), SIMD3(960, 540, -500)))
        #expect(near(Space3D.dolly(eye: eye, target: t, factor: 0), SIMD3(960, 540, -10)))  // min distance
        let (de, dt) = Space3D.eyeTarget(nil, width: 1920, height: 1080)
        let cam = CameraState.make(nil, width: 1920, height: 1080)
        #expect(near(de, cam.position) && dt == SIMD3(960, 540, 0))
        #expect(Space3D.json(SIMD3(1.04, 2, 3)) == [.number(1), .number(2), .number(3)])
    }

    @Test func dropKinds() {
        #expect(DropKind.of(URL(fileURLWithPath: "/a/b.PNG")) == .image)
        #expect(DropKind.of(URL(fileURLWithPath: "/a/b.aiff")) == .audio)
        #expect(DropKind.of(URL(fileURLWithPath: "/a/b.m4a")) == .audio)
        #expect(DropKind.of(URL(fileURLWithPath: "/a/b.otf")) == .font)
        #expect(DropKind.of(URL(fileURLWithPath: "/a/b.svg")) == .svg)
        #expect(DropKind.of(URL(fileURLWithPath: "/a/b.txt")) == .unsupported)
    }

    @Test func sharedGeometryHelpers() {
        let r = CGRect(x: 10, y: 20, width: 30, height: 40)
        #expect(
            r.corners == [CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 20), CGPoint(x: 40, y: 60), CGPoint(x: 10, y: 60)])
        #expect(ViewZoom.canvasPoint(CGPoint(x: 100, y: 50), scale: 0.5) == CGPoint(x: 200, y: 100))
        let o = ViewZoom.canvasOrigin(
            view: CGSize(width: 1000, height: 800), canvas: CGSize(width: 400, height: 200), scale: 2,
            pan: CGSize(width: 5, height: -5))
        #expect(o == CGPoint(x: 500 + 5 - 400, y: 400 - 5 - 200))
    }

    // MARK: Document commands

    func makeDoc() throws -> (EditorDocument, URL) {
        var s = ArclightCore.Scene(id: "s", duration: 4)
        s.nodes = [
            Node(
                id: "a", type: "shape",
                props: [
                    "shape": .value("rect"), "x": .value(100), "y": .value(100), "width": .value(100),
                    "height": .value(50),
                ]),
            Node(
                id: "b", type: "shape",
                props: [
                    "shape": .value("rect"), "x": .value(400), "y": .value(300), "width": .value(200),
                    "height": .value(100),
                ]),
            Node(
                id: "c", type: "shape",
                props: [
                    "shape": .value("rect"), "x": .keys([Keyframe(t: 0, v: 900), Keyframe(t: 2, v: 1000)]),
                    "y": .value(500), "width": .value(40), "height": .value(40),
                ]),
            Node(id: "crowd", type: "repeater", props: ["y": .value(800)]),
        ]
        let made = try ArclightCoreTests.makeDoc(scene: s)
        return (made.doc, made.project.url)
    }

    @Test(.requiresMetal) func alignNudgeAndUndo() throws {
        let (doc, url) = try makeDoc()
        defer { try? FileManager.default.removeItem(at: url) }
        doc.selection = "a"; doc.multiSelection = ["b"]
        doc.align(.left)
        let nodes = doc.evaluate()
        let ra = doc.canvasRect(nodes.first { $0.node.id == "a" }!)!,
            rb = doc.canvasRect(nodes.first { $0.node.id == "b" }!)!
        #expect(abs(ra.minX - rb.minX) < 0.5 && doc.scene.node("a")?.props["x"] == .value(100))
        doc.undo()
        #expect(doc.scene.node("b")?.props["x"] == .value(400))
        // Single layer: align to the canvas centre.
        doc.multiSelection = []; doc.selection = "b"
        doc.align(.hCenter)
        #expect(doc.scene.node("b")?.props["x"] == .value(960))
        // Nudge needs canvas focus.
        CanvasFocus.doc = nil
        #expect(!doc.nudge(dx: 1, dy: 0))
        CanvasFocus.doc = ObjectIdentifier(doc)
        defer { CanvasFocus.doc = nil }
        #expect(doc.nudge(dx: 10, dy: -1))
        #expect(doc.scene.node("b")?.props["x"] == .value(970) && doc.scene.node("b")?.props["y"] == .value(299))
        // Animated prop: the nudge auto-keys at the playhead.
        doc.selection = "c"; doc.time = 1
        doc.nudge(dx: 5, dy: 0)
        if case .keys(let ks)? = doc.scene.node("c")?.props["x"] {
            #expect(ks.contains { $0.t == 1 && $0.v == .number(955) })
        } else {
            Issue.record("x should stay keyframed")
        }
    }

    @Test(.requiresMetal) func movableAndOrbitRules() throws {
        let (doc, url) = try makeDoc()
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(doc.canOrbitCamera)
        doc.selection = "a"
        #expect(!doc.canOrbitCamera && doc.selected3D == nil)
        doc.selection = "crowd"
        #expect(doc.canOrbitCamera && doc.selected3D == "crowd" && doc.movable2D(doc.evaluate()).isEmpty)
        doc.toggleCanvasSelection("a")
        #expect(doc.selection == "a" && doc.multiSelection == ["crowd"] && doc.selected3D == nil)
        let ids = doc.movable2D(doc.evaluate()).map(\.node.id)
        #expect(ids == ["a"])
    }

    @Test(.requiresMetal) func floorPickingAndCameraWrites() throws {
        let (doc, url) = try makeDoc()
        defer { try? FileManager.default.removeItem(at: url) }
        // Default camera: a canvas pixel maps back to the floor point that projects onto it.
        let p = SIMD3<Float>(700, 800, 250)
        let c = doc.project(p)!
        let back = doc.floorPoint(c, planeY: 800)!
        #expect(near(back, p, 0.5))
        // Orbit/dolly write position (+ target when missing) as a constant.
        doc.dollyCamera(factor: 0.5)
        let cam = doc.scene.camera?.rawValue(at: 0)?.object
        #expect(cam?["position"] != nil && cam?["target"] == [.number(960), .number(540), .number(0)])
        // Keyframed camera: a key at the playhead.
        doc.edit { $0.camera = .keys([Keyframe(t: 0, v: ["position": [960, 540, -1500], "target": [960, 540, 0]])]) }
        doc.time = 2
        doc.setCamera(eye: SIMD3(100, 200, -300), target: SIMD3(960, 540, 0))
        if case .keys(let ks)? = doc.scene.camera {
            #expect(
                ks.count == 2 && ks.last?.t == 2
                    && ks.last?.v.object?["position"] == [.number(100), .number(200), .number(-300)])
        } else {
            Issue.record("camera should stay keyframed")
        }
    }

    @Test(.requiresMetal) func dropFilesImportsImageAudioAndFont() throws {
        let (doc, url) = try makeDoc()
        defer { try? FileManager.default.removeItem(at: url) }
        let src = FileManager.default.temporaryDirectory.appendingPathComponent("drop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: src) }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4000, pixelsHigh: 1000, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = src.appendingPathComponent("pic.png")
        try rep.representation(using: .png, properties: [:])!.write(to: png)
        let wav = src.appendingPathComponent("voice.wav"); try Data([0, 1, 2]).write(to: wav)
        let ttf = src.appendingPathComponent("Brand.ttf"); try Data([0, 1, 2]).write(to: ttf)
        doc.dropFiles([png, wav, ttf], at: CGPoint(x: 300.4, y: 200))
        let img = doc.scene.nodes.first { $0.type == "image" }
        #expect(
            img?.props["src"] == .value("pic.png") && img?.props["x"] == .value(300) && img?.props["y"] == .value(200))
        #expect(img?.props["width"] == .value(1536))  // 4000×1000 fitted into 80% of 1920×1080
        #expect(doc.selection == img?.id)
        #expect(doc.scene.audio?.src == "voice.wav")
        #expect(FileManager.default.fileExists(atPath: doc.assets.appendingPathComponent("pic.png").path))
        #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("fonts/Brand.ttf").path))
        // Dropping a file that's already in assets/ doesn't delete it.
        doc.dropFiles([doc.assets.appendingPathComponent("pic.png")], at: .zero)
        #expect(FileManager.default.fileExists(atPath: doc.assets.appendingPathComponent("pic.png").path))
    }
}
