import Foundation
import Testing

@testable import ArclightEditor

/// The settings keys are stored in users' preferences: pin them.
@Suite struct PreferencesTests {
    @Test func keysAreStable() {
        let keys = [
            Pref.theme, Pref.performance, Pref.snapping, Pref.leftWidth, Pref.rightWidth, Pref.timelineHeight,
            Pref.aiPanel, Pref.aiFloat, Pref.legacyAIWidth, Pref.activityWho, Pref.activityThisScene,
            Pref.activityReads,
            Pref.notesCollapsed, Pref.assetsCollapsed, Pref.layerDensity, Pref.rulers, Pref.centerLines, Pref.safeAreas,
            Pref.thirds, Pref.canvasSnap, Pref.recentProjects, Pref.clickTrace,
        ]
        #expect(
            keys == [
                "ui.theme", "ui.performance", "ui.snapping", "ui.leftWidth", "ui.rightWidth", "ui.timelineHeight",
                "ui.aiPanel", "ui.aiFloat", "ui.aiWidth", "ui.activity.who", "ui.activity.thisScene",
                "ui.activity.reads",
                "ui.notes.collapsed", "ui.assets.collapsed", "layers.density", "canvas.rulers", "canvas.centerLines",
                "canvas.safeAreas", "canvas.thirds", "canvas.snap", "recentProjects", "debug.clickTrace",
            ])
        #expect(Pref.activitySeen(URL(fileURLWithPath: "/tmp/a/../P.arclight")) == "ui.activitySeen./tmp/P.arclight")
        #expect(Pref.layersCollapsed(projectPath: "/p", scene: "s") == "layers.collapsed./p.s")
    }

    /// Tests, like off-screen commands, keep the editor's settings in a throwaway domain: nothing reaches the test
    /// runner's real settings (`CFFIXED_USER_HOME` doesn't move UserDefaults).
    @Test func testsKeepEditorSettingsOutOfTheStandardDomain() {
        #expect(Pref.store !== UserDefaults.standard)
        let key = "arclight.tests.\(UUID().uuidString)"
        Pref.store.set(true, forKey: key)
        defer { Pref.store.removeObject(forKey: key) }
        #expect(Pref.store.bool(forKey: key))
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }

    /// The off-screen commands' store is a file in its own folder, not a domain in ~/Library/Preferences.
    @Test func throwawayStoreIsAFileInItsFolder() throws {
        let tmp = try TempDefaults()
        defer { tmp.remove() }
        let store = try #require(Pref.throwawayStore(in: tmp.folder))
        #expect(store !== UserDefaults.standard)
        let key = "arclight.tests.\(UUID().uuidString)"
        store.set("light", forKey: key)
        store.synchronize()
        #expect(FileManager.default.fileExists(atPath: tmp.folder.appendingPathComponent("settings.plist").path))
        #expect(UserDefaults.standard.object(forKey: key) == nil)
    }
}
