import Foundation

/// Every UserDefaults key the editor uses. Views read them with `@AppStorage(Pref.x)`. The strings are stored in
/// users' settings: never change one without migrating it.
enum Pref {
    /// Where the editor keeps these settings: the standard domain, except in off-screen commands (`snapshot`,
    /// `clickprobe`), which use a throwaway domain in a temp folder (`throwawayStore`), and in tests. Views read
    /// it through `.themedRoot()`, which makes it their `@AppStorage` store. (`CFFIXED_USER_HOME` moves the user's
    /// folders but not UserDefaults: cfprefsd keeps those in the real home.)
    static var store: UserDefaults = {
        // A test run (`swift test` passes the .xctest bundle on the command line) keeps the editor's settings in a
        // throwaway domain too, so tests never change the test runner's real one.
        guard ProcessInfo.processInfo.arguments.contains(where: { $0.contains(".xctest") }),
            let d = throwawayStore(in: testFolder)
        else { return .standard }
        atexit { try? FileManager.default.removeItem(at: Pref.testFolder) }
        return d
    }()
    private static var testFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "arclight-test-settings-\(ProcessInfo.processInfo.processIdentifier)")
    }

    /// A settings domain that is a file in `folder` (nothing is read from or written to ~/Library/Preferences).
    /// The caller removes the folder.
    static func throwawayStore(in folder: URL) -> UserDefaults? {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return UserDefaults(suiteName: folder.appendingPathComponent("settings").path)
    }

    // Appearance and editing
    static let theme = "ui.theme"
    static let performance = "ui.performance"
    static let snapping = "ui.snapping"

    // Window layout
    static let leftWidth = "ui.leftWidth"
    static let rightWidth = "ui.rightWidth"
    static let timelineHeight = "ui.timelineHeight"

    // AI panel
    static let aiPanel = "ui.aiPanel"
    static let aiFloat = "ui.aiFloat"
    /// Width of the docked AI panel before it floated; read once by `AIPanelLayout.load`, then removed.
    static let legacyAIWidth = "ui.aiWidth"
    /// The last activity entry seen in this project (unread badge).
    static func activitySeen(_ project: URL) -> String { "ui.activitySeen." + project.standardizedFileURL.path }

    // Activity, notes, assets
    static let activityWho = "ui.activity.who"
    static let activityThisScene = "ui.activity.thisScene"
    static let activityReads = "ui.activity.reads"
    static let notesCollapsed = "ui.notes.collapsed"
    static let assetsCollapsed = "ui.assets.collapsed"

    // Layers
    static let layerDensity = "layers.density"
    /// Collapsed groups of one scene (`projectPath` may be empty).
    static func layersCollapsed(projectPath: String, scene: String) -> String {
        "layers.collapsed.\(projectPath).\(scene)"
    }

    // Canvas guides
    static let rulers = "canvas.rulers"
    static let centerLines = "canvas.centerLines"
    static let safeAreas = "canvas.safeAreas"
    static let thirds = "canvas.thirds"
    /// Old canvas-only snapping switch. The canvas follows `snapping` now; read once by `storedSnapping`, then removed.
    static let canvasSnap = "canvas.snap"

    // Other
    static let recentProjects = "recentProjects"
    static let clickTrace = "debug.clickTrace"

    /// The stored `snapping` setting (default on). An old `canvas.snap` is read once: it becomes `snapping` when
    /// that was never set (an explicit `snapping` wins), and is removed.
    static func storedSnapping(_ d: UserDefaults = Pref.store) -> Bool {
        if let old = d.object(forKey: canvasSnap) as? Bool {
            if d.object(forKey: snapping) == nil { d.set(old, forKey: snapping) }
            d.removeObject(forKey: canvasSnap)
        }
        return d.object(forKey: snapping) as? Bool ?? true
    }
}
