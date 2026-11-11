import ArclightCore
import Foundation

extension EditorDocument {
    // MARK: Scenes

    var scenes: [Scene] { store.orderedScenes.map { $0.id == scene.id ? scene : $0 } }

    func open(scene id: String) {
        saveNow()
        guard let s = store.scenes[id] else { return }
        switchTo(s)
    }

    /// Makes `s` the open scene with fresh per-scene state: no undo history (it belongs to the previous scene),
    /// selection, solo, work area or highlights, and a stopped playhead at 0.
    func switchTo(_ s: Scene) {
        savePending?.cancel(); savePending = nil
        scene = s; baseRev = s.rev
        undoStack.removeAll(); redoStack.removeAll()
        selection = nil; multiSelection = []; soloIds = []; workArea = nil; flashIds = []
        playing = false; time = 0
        zoomToFit(animated: false)
    }

    func newScene() {
        saveNow()
        var k = store.scenes.count + 1
        while store.scenes["scene-\(k)"] != nil { k += 1 }
        var s = Scene(id: "scene-\(k)", duration: 5)
        s.name = "Scene \(k)"
        s.background = .value("$bg")
        if let saved = try? store.save(scene: s, summary: "create", source: .editor) {
            refreshProject(); open(scene: saved.id)
        }
    }

    func duplicateScene(_ id: String) {
        saveNow()
        guard var s = store.scenes[id] else { return }
        var k = 2
        while store.scenes["\(id)-\(k)"] != nil { k += 1 }
        s.id = "\(id)-\(k)"; s.rev = 0; s.name = (s.name ?? id) + " copy"
        if let saved = try? store.save(scene: s, summary: "duplicate", source: .editor) {
            refreshProject(); open(scene: saved.id)
        }
    }

    func deleteScene(_ id: String) {
        guard store.scenes.count > 1 else { flash("A project needs at least one scene"); return }
        try? store.deleteScene(id)
        refreshProject()
        if id == scene.id, let first = store.orderedScenes.first { switchTo(first) }
    }

    func refreshProject() { project = store.project; stamps = fileStamps() }

    // MARK: Canvas & frame rate

    struct CanvasPreset: Hashable { let name: String; let w: Int; let h: Int }
    static let presets = [
        CanvasPreset(name: "Landscape 16:9 · 1080p", w: 1920, h: 1080),
        CanvasPreset(name: "Landscape 16:9 · 4K", w: 3840, h: 2160),
        CanvasPreset(name: "Landscape 16:9 · 720p", w: 1280, h: 720),
        CanvasPreset(name: "Vertical 9:16 · Shorts / Reels / TikTok", w: 1080, h: 1920),
        CanvasPreset(name: "Square 1:1", w: 1080, h: 1080),
        CanvasPreset(name: "Portrait 4:5 · feed", w: 1080, h: 1350),
        CanvasPreset(name: "Cinema 2.39:1", w: 1920, h: 804),
    ]
    static let frameRates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 60]

    func setProjectCanvas(width: Int, height: Int) {
        guard width >= 16, height >= 16 else { return }
        var p = store.project
        p.size = [width, height]
        try? store.update(project: p)
        refreshProject()
        flash("Canvas \(width)×\(height)")
    }

    func setProjectFPS(_ f: Double) {
        guard f > 0 else { return }
        var p = store.project
        p.fps = f
        try? store.update(project: p)
        refreshProject()
    }

    /// Per-scene overrides (nil = use the project's).
    func setSceneCanvas(_ size: [Int]?) { edit { $0.size = size } }
    func setSceneFPS(_ f: Double?) { edit { $0.fps = f } }

    func renameProject(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != project.name else { return }
        var p = store.project
        p.name = n
        try? store.update(project: p)
        refreshProject()
    }

    func renameScene(_ id: String, _ name: String) {
        if id == scene.id { edit { $0.name = name.isEmpty ? nil : name }; saveNow(); return }
        guard var s = store.scenes[id] else { return }
        s.name = name.isEmpty ? nil : name
        _ = try? store.save(scene: s, summary: "rename", source: .editor)
        refreshProject()
    }
}

extension EditorDocument.CanvasPreset {
    /// Short, distinct name: "HD 1080p", "4K UHD", "Vertical"…
    var title: String { Self.known[[w, h]]?.0 ?? name.components(separatedBy: " · ").first ?? name }

    /// Aspect ratio and use: "16:9", "9:16 · Shorts, Reels, TikTok"…
    var subtitle: String {
        if let s = Self.known[[w, h]]?.1 { return s }
        let parts = name.components(separatedBy: " · ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: " · ") : ""
    }

    private static let known: [[Int]: (String, String)] = [
        [1920, 1080]: ("HD 1080p", "16:9"),
        [3840, 2160]: ("4K UHD", "16:9"),
        [1280, 720]: ("HD 720p", "16:9"),
        [1080, 1920]: ("Vertical", "9:16 · Shorts, Reels, TikTok"),
        [1080, 1080]: ("Square", "1:1"),
        [1080, 1350]: ("Portrait", "4:5 · feed posts"),
        [1920, 804]: ("Cinema", "2.39:1 widescreen"),
    ]
}
