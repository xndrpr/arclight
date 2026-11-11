import AppKit
import ArclightCore
import Combine
import Foundation

/// One open project in the editor. Owns the working copy of the current scene, undo history,
/// debounced autosave, and live reload of changes made on disk (e.g. by an AI agent over MCP).
final class EditorDocument: ObservableObject {
    /// Off for `arclight snapshot`, so development renders don't fill the user's Recent list.
    static var recordRecents = true

    let store: ProjectStore
    let renderer: Renderer

    // Set only by the Document+*.swift extensions (they live in other files, so the setters can't be private).
    @Published var project: Project
    @Published var scene: Scene
    @Published var selection: String? { didSet { if selection != oldValue { stateChanged() } } }
    /// Playhead (scene seconds). Published at a reduced rate while playing; see `playTime`.
    @Published var time: Double = 0 { didSet { if !playing { playTime = time }; stateChanged() } }
    @Published var playing = false {
        didSet { if playing { lastTick = CACurrentMediaTime(); playTime = time } else { rate = 1 } }
    }
    /// Shuttle speed (J/K/L): negative plays backwards.
    @Published var rate: Double = 1
    /// Half-resolution preview for heavy scenes. Off by default; remembered per user.
    @Published var performance = Pref.store.bool(forKey: Pref.performance) {
        didSet { Pref.store.set(performance, forKey: Pref.performance) }
    }
    @Published var toast: String?
    /// Timeline view: seconds visible across the track area (the zoom) and the left edge (seconds).
    /// Panning only moves the offset, never the scale; changing the duration never rescales.
    @Published var tlVisible: Double = 10
    @Published var tlOffset: Double = 0
    /// One setting for the timeline and the canvas.
    @Published var snapping = Pref.storedSnapping()
    /// Loop playback (⌘L) and the optional work area (⌥-drag on the ruler) it loops inside.
    @Published var loopEnabled = true
    @Published var workArea: ClosedRange<Double>?
    /// Full-screen cinema viewer / viewer-only layout.
    @Published var cinema = false
    @Published var viewerOnly = false
    @Published var busy: String?
    var onCinemaChange: ((Bool) -> Void)?

    // Shared editor state used by several panels (activity, layers, canvas, inspector).
    /// Project activity feed (MCP calls by the AI, editor saves), oldest first.
    @Published var activity: [ActivityEntry] = []
    /// Set when new AI (MCP) calls arrive; the top bar shows "AI is editing" until then.
    @Published var agentActiveUntil: Date?
    /// Layers changed outside the editor, highlighted briefly.
    @Published var flashIds: Set<String> = []
    /// Extra selected layers (⌘/⇧-click); `selection` stays the primary one.
    @Published var multiSelection: Set<String> = []
    /// Solo: when non-empty, only these layers render in the viewport.
    @Published var soloIds: Set<String> = []
    /// Left sidebar tab id: "scenes", "history" or "assets".
    @Published var leftTab = "scenes"

    /// Primary + extra selection.
    var selectedIds: Set<String> { multiSelection.union(selection.map { [$0] } ?? []) }

    /// Precise playhead used by the viewport while playing.
    var playTime: Double = 0

    // Internal state of the Document+*.swift extensions (internal only because they live in other files).
    var lastTick: CFTimeInterval = 0
    var lastPublish: CFTimeInterval = 0
    var undoStack: [Scene] = [], redoStack: [Scene] = []
    /// Undo history of project theme edits (Document+Theme.swift).
    let themeHistory = ThemeHistory()
    /// Bumped when library files change (imports, deletes, saved templates) so panels re-read the folders.
    @Published var libraryVersion = 0
    var inGesture = false
    /// Rev of the on-disk scene our working copy is based on.
    var baseRev: Int
    var savePending: DispatchWorkItem?
    var stamps: [String: Date] = [:]
    var stateWork: DispatchWorkItem?
    var activityStamp: Date?
    var zoomTween: Timer?

    private var pollTimer: Timer?
    private var gestureRecorded = false

    var url: URL { store.url }
    var assets: URL { store.assetsURL }
    var fps: Double { scene.fps ?? project.fps }
    var canvasSize: CGSize { let (w, h) = project.size(for: scene); return CGSize(width: w, height: h) }

    init(url: URL) throws {
        let st = try ProjectStore(url: url)
        if st.orderedScenes.isEmpty {
            var s = Scene(id: "scene-1", duration: 5)
            s.name = "Scene 1"
            try st.save(scene: s, summary: "create")
        }
        let first = try st.scene(nil)
        store = st
        renderer = try Renderer()
        renderer.draft = true
        project = st.project
        scene = first
        baseRev = first.rev
        stamps = fileStamps()
        tlVisible = fitSpan()
        refreshActivity(force: true)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        if EditorDocument.recordRecents { Recents.add(url) }
    }

    deinit { pollTimer?.invalidate() }

    // MARK: Editing

    /// Applies a change to the working scene with undo. Inside a gesture, only the first change records undo.
    /// With `grow`, an edit that puts keys or in points past END extends the scene to include them (`SceneExtent`).
    func edit(grow: Bool = true, _ change: (inout Scene) -> Void) {
        var s = scene
        change(&s)
        if grow, let d = SceneExtent.grownDuration(before: scene, after: s, fps: fps) {
            s.duration = d
            flash("Scene extended to \(fmt((d * 100).rounded() / 100)) s to include it — drag END to change")
        }
        guard s != scene else { return }
        if !inGesture || !gestureRecorded {
            undoStack.append(scene)
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
            if inGesture { gestureRecorded = true }
        }
        scene = s
        scheduleSave()
    }

    /// Applies MCP-style scene ops (same code path the AI uses).
    func apply(_ ops: [JSONValue]) {
        do {
            let r = try SceneOps.apply(ops, to: scene)
            edit { $0 = r.scene }
        } catch { flash("\(error)") }
    }

    func beginGesture() { inGesture = true; gestureRecorded = false }
    func endGesture() { inGesture = false; gestureRecorded = false; saveNow() }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(scene); scene = prev; scheduleSave()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(scene); scene = next; scheduleSave()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Sets a prop on a node with auto-key at the playhead when the prop is animated.
    func set(_ id: String, _ prop: String, _ value: JSONValue) {
        let local = time - (scene.node(id)?.start ?? 0)
        edit { SceneOps.setProp(&$0, id: id, prop: prop, value: value, localTime: local) }
    }

    func setRaw(_ id: String, _ prop: String, _ p: Prop?) {
        edit { s in
            guard let i = s.nodes.firstIndex(where: { $0.id == id }) else { return }
            s.nodes[i].props[prop] = p
        }
    }

    // MARK: Evaluation helpers

    /// Evaluated layers at `t` (default: what the viewer shows, i.e. the last frame past END).
    func evaluate(at t: Double? = nil) -> [EvalNode] {
        renderer.evaluator.theme = project.theme
        return renderer.evaluator.evaluate(scene, T: t ?? viewTime)
    }

    func flash(_ msg: String) {
        toast = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in if self?.toast == msg { self?.toast = nil }
        }
    }
}
