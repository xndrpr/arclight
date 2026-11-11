import AppKit
import ArclightCore
import CoreText
import Foundation
import simd

extension EvalNode {
    /// The layer's anchor point in layer pixels ((0, 0) when unset).
    var anchor: CGPoint {
        let a = props["anchor"]?.doubles ?? [0, 0]
        return CGPoint(x: a.first ?? 0, y: a.count > 1 ? a[1] : 0)
    }
}

/// Canvas-tool commands on the document: geometry of evaluated layers, multi-layer edits, nudge, align,
/// 3D move / camera orbit and dropped files.
extension EditorDocument {
    // MARK: Geometry of evaluated layers

    /// Canvas-pixel corners (TL, TR, BR, BL) of a 2D layer's bounds.
    func canvasQuad(_ n: EvalNode) -> [CGPoint]? {
        guard !n.is3D, let b = renderer.localBounds(n) else { return nil }
        return b.corners.map { p in
            let w = n.world * SIMD4<Float>(Float(p.x), Float(p.y), 0, 1)
            return CGPoint(x: CGFloat(w.x), y: CGFloat(w.y))
        }
    }

    func canvasRect(_ n: EvalNode) -> CGRect? { canvasQuad(n).map(TransformMath.bounds) }

    /// Layers covering (almost) the whole frame — backgrounds — are only picked with ⌥ and never snapped to.
    func isFullFrame(_ n: EvalNode) -> Bool {
        guard let b = renderer.localBounds(n) else { return false }
        let s = CGFloat(M.maxScale(n.world))
        return b.width * b.height * s * s >= canvasSize.width * canvasSize.height * 0.9
    }

    /// Canvas pivot (anchor point) of a layer.
    func pivot(_ n: EvalNode) -> CGPoint {
        let a = n.anchor
        let w = n.world * SIMD4<Float>(Float(a.x), Float(a.y), 0, 1)
        return CGPoint(x: CGFloat(w.x), y: CGFloat(w.y))
    }

    /// Inverse world matrix of a node's parent (identity at the root).
    private func parentInverse(_ n: EvalNode, in nodes: [EvalNode]) -> simd_float4x4 {
        n.node.parent.flatMap { pid in nodes.first { $0.node.id == pid }?.world.inverse } ?? matrix_identity_float4x4
    }

    /// Selected layers that aren't inside another selected layer.
    private var topLevelSelectedIds: Set<String> {
        Set(LayerTree.topLevel(scene, selectedIds.filter { scene.node($0) != nil }))
    }

    /// Selected 2D layers that can be transformed on the canvas (unlocked, not inside another selected layer).
    func movable2D(_ nodes: [EvalNode]) -> [EvalNode] {
        let ids = topLevelSelectedIds
        return nodes.filter {
            ids.contains($0.node.id) && !$0.is3D && !isLocked($0.node.id) && renderer.localBounds($0) != nil
        }
    }

    /// The selected 3D layer that can be dragged on its floor (a single repeater or light).
    var selected3D: String? {
        guard selectedIds.count == 1, let id = selection, let n = scene.node(id),
            n.type == "repeater" || n.type == "light", !isLocked(id)
        else { return nil }
        return id
    }

    /// ⌥-drag orbit / ⌥-scroll dolly is available with nothing or a 3D layer selected.
    var canOrbitCamera: Bool {
        guard let id = selection else { return true }
        if id == "@camera" { return true }
        guard let n = scene.node(id) else { return true }
        return n.type == "repeater" || n.type == "light" || n.props["3d"] == .value(true)
    }

    private var canvasFocused: Bool { CanvasFocus.doc == ObjectIdentifier(self) }

    // MARK: Multi-layer edits

    /// Sets several props in one edit (auto-keying animated ones at the playhead).
    func setProps(_ changes: [(id: String, prop: String, value: JSONValue)]) {
        guard !changes.isEmpty else { return }
        edit { s in
            for c in changes {
                let local = time - (s.node(c.id)?.start ?? 0)
                SceneOps.setProp(&s, id: c.id, prop: c.prop, value: c.value, localTime: local)
            }
        }
    }

    /// Moves layers by canvas-space offsets (converted into each parent's space). One edit.
    func offsetLayers(_ moves: [(node: EvalNode, by: CGSize)], in nodes: [EvalNode]) {
        var ch: [(id: String, prop: String, value: JSONValue)] = []
        for (n, d) in moves where d != .zero { ch += positionChanges(n, by: d, in: nodes) }
        setProps(ch)
    }

    /// The x/y edits that move `n` by a canvas-space offset (converted into its parent's space).
    func positionChanges(
        _ n: EvalNode, by d: CGSize, in nodes: [EvalNode]
    ) -> [(id: String, prop: String, value: JSONValue)] {
        let l = parentInverse(n, in: nodes) * SIMD4<Float>(Float(d.width), Float(d.height), 0, 0)
        return [
            (n.node.id, "x", .number((n.num("x", 0) + Double(l.x)).rounded())),
            (n.node.id, "y", .number((n.num("y", 0) + Double(l.y)).rounded())),
        ]
    }

    /// ⇧-click on the canvas.
    func toggleCanvasSelection(_ id: String) {
        let r = CanvasSelection.toggle(id, primary: selection, extras: multiSelection)
        multiSelection = r.extras
        selection = r.primary
    }

    /// ⌘-arrow nudge (⌘⇧ = 10 px) of the selected layers, when the canvas has focus.
    @discardableResult
    func nudge(dx: Double, dy: Double) -> Bool {
        guard canvasFocused else { return false }
        let nodes = evaluate()
        let ids = topLevelSelectedIds
        let targets = nodes.filter { ids.contains($0.node.id) && !isLocked($0.node.id) }
        guard !targets.isEmpty else { return false }
        offsetLayers(targets.map { ($0, CGSize(width: dx, height: dy)) }, in: nodes)
        return true
    }

    /// Align / distribute the selected 2D layers (a single layer aligns to the canvas). One undo step.
    func align(_ mode: AlignMode) {
        let nodes = evaluate()
        let items = movable2D(nodes).compactMap { n in canvasRect(n).map { (n, $0) } }
        guard !items.isEmpty, !(mode.isDistribute && items.count < 3) else { return }
        let bounds = items.count == 1 ? CGRect(origin: .zero, size: canvasSize) : nil
        let offs = Align.offsets(items.map(\.1), mode, to: bounds)
        offsetLayers(zip(items, offs).map { ($0.0, $1) }, in: nodes)
    }

    // MARK: 3D

    private func cameraState(at T: Double? = nil) -> CameraState {
        let t = T ?? time
        let cs = canvasSize
        renderer.evaluator.theme = project.theme
        return CameraState.make(
            renderer.evaluator.sceneValue(scene.camera, scene, T: t),
            width: Float(cs.width), height: Float(cs.height), time: t)
    }

    /// Resolved camera value at the playhead (eye/target with defaults).
    func cameraEyeTarget() -> (eye: SIMD3<Float>, target: SIMD3<Float>) {
        renderer.evaluator.theme = project.theme
        let v = renderer.evaluator.sceneValue(scene.camera, scene, T: time)
        return Space3D.eyeTarget(v, width: Float(canvasSize.width), height: Float(canvasSize.height))
    }

    /// Writes the camera eye (and target when the camera has none yet), as a key at the playhead if keyframed.
    func setCamera(eye: SIMD3<Float>, target: SIMD3<Float>) {
        let t = time
        edit { s in
            var p = s.camera ?? .value(.object([:]))
            if case .value(let v) = p, v.object == nil { p = .value(.object([:])) }
            let hasTarget = (p.rawValue(at: t)?.object?["target"]) != nil
            p = p.setting(path: ["position"], to: Space3D.json(eye), at: t) ?? p
            if !hasTarget { p = p.setting(path: ["target"], to: Space3D.json(target), at: t) ?? p }
            s.camera = p
        }
    }

    func dollyCamera(factor: Float) {
        let (eye, target) = cameraEyeTarget()
        setCamera(eye: Space3D.dolly(eye: eye, target: target, factor: factor), target: target)
    }

    /// Canvas point of a world position (nil when behind the camera).
    func project(_ p: SIMD3<Float>) -> CGPoint? {
        let c = cameraState().viewProj * SIMD4<Float>(p, 1)
        guard c.w > 1e-4 else { return nil }
        let cs = canvasSize
        return CGPoint(x: CGFloat((c.x / c.w + 1) / 2) * cs.width, y: CGFloat((1 - c.y / c.w) / 2) * cs.height)
    }

    /// World point on the horizontal plane y = `planeY` under a canvas pixel.
    func floorPoint(_ c: CGPoint, planeY: Float) -> SIMD3<Float>? {
        let r = cameraState().ray(
            at: SIMD2(Float(c.x), Float(c.y)), width: Float(canvasSize.width), height: Float(canvasSize.height))
        return Space3D.hitPlane(origin: r.origin, dir: r.dir, planeY: planeY)
    }

    // MARK: Dropped files

    /// Imports files dropped from Finder at canvas point `c`: images become image layers, audio becomes the
    /// scene's audio, fonts are copied into fonts/ and registered.
    func dropFiles(_ urls: [URL], at c: CGPoint) {
        var notes: [String] = []
        var k = 0
        for u in urls {
            do {
                switch DropKind.of(u) {
                case .image:
                    let name = try importIfNeeded(u)
                    var props: [String: JSONValue] = [
                        "src": .string(name), "x": .number((c.x + CGFloat(k * 24)).rounded()),
                        "y": .number((c.y + CGFloat(k * 24)).rounded()),
                    ]
                    if let w = fittedWidth(u) { props["width"] = .number(w) }
                    addNode("image", props: props)
                    k += 1
                    notes.append(name)
                case .audio:
                    let name = try importIfNeeded(u)
                    edit { $0.audio = AudioRef(src: name) }
                    notes.append("audio \(name)")
                case .font:
                    let dir = url.appendingPathComponent("fonts")
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent(u.lastPathComponent)
                    if dest.standardizedFileURL != u.standardizedFileURL {
                        if FileManager.default.fileExists(atPath: dest.path) {
                            try FileManager.default.removeItem(at: dest)
                        }
                        try FileManager.default.copyItem(at: u, to: dest)
                    }
                    ProjectStore.registerFonts(in: url)
                    notes.append("font \(Self.fontFamily(dest) ?? u.deletingPathExtension().lastPathComponent)")
                case .svg:
                    notes.append("SVG not supported yet (\(u.lastPathComponent))")
                case .unsupported:
                    notes.append("can't import \(u.lastPathComponent)")
                }
            } catch {
                notes.append("\(u.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !notes.isEmpty { flash("Dropped · " + notes.joined(separator: ", ")) }
    }

    /// Copies into assets/ unless the file already lives there (copying onto itself would delete it).
    private func importIfNeeded(_ u: URL) throws -> String {
        if u.deletingLastPathComponent().standardizedFileURL == assets.standardizedFileURL {
            return u.lastPathComponent
        }
        return try store.importAsset(from: u)
    }

    /// Width that fits a large image into 80% of the canvas (nil when it already fits).
    private func fittedWidth(_ u: URL) -> Double? {
        guard let rep = NSImageRep(contentsOf: u), rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        let w = Double(rep.pixelsWide), h = Double(rep.pixelsHigh)
        let k = min(Double(canvasSize.width) * 0.8 / w, Double(canvasSize.height) * 0.8 / h)
        return k < 1 ? (w * k).rounded() : nil
    }

    private static func fontFamily(_ u: URL) -> String? {
        guard let ds = CTFontManagerCreateFontDescriptorsFromURL(u as CFURL) as? [CTFontDescriptor], let d = ds.first
        else { return nil }
        return CTFontDescriptorCopyAttribute(d, kCTFontFamilyNameAttribute) as? String
    }
}
